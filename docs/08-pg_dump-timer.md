> 이 문서는 `3tier-rocky10-guide-v16.md` 의 3802~4110줄을 옮겨 공개용으로 문장을 다듬은 것이다. 코드, 명령, 출력, 설정값은 원본 그대로이고, 비밀번호와 로컬 경로만 자리표시자로 바꿨다.

## 15. pg_dump 논리 백업 자동화 (db02, Primary)

> ✅ 이 챕터는 실제로 구현하고, systemd 유닛을 만들어 수동 실행으로 검증한 뒤 timer를 활성화하는 것까지 마쳤다.

### 15-1. 설계

1. 실행 위치: db02 (Primary). 논리 백업은 실사용 트래픽을 받는 쪽에서 뜨는 게 최신 상태를 보장한다.

2. 백업 범위: `appdb`(`pg_dump -Fc`) + 전역 객체(`pg_dumpall --globals-only`). globals에는 `app_user`/`replicator` role과 SCRAM 비밀번호 해시가 들어있어, 새 서버에 완전히 처음부터 복원하려면 반드시 필요하다.

3. 주기: 매일 02:00. appdb가 아직 작고(수 MB) 변경도 잦지 않아 하루 1회로 충분하다고 판단했다.

4. 보관 기간: 7일 (`mtime` 기준 `find -delete`). 기존 §6-9 스크립트와 동일한 정책이다.

5. 스케줄러: systemd timer (`pg-logical-backup.timer`). cron 대신 선택했다. `journalctl -u`로 실행 로그가 남고, `Persistent=true`로 VM이 02:00에 꺼져 있었어도 다음 부팅 시 밀린 백업을 보충 실행한다.

### 15-2. 사전 조치: `/pgbackup` 소유권 수정

```bash
sudo -u postgres touch /pgbackup/_writetest
# touch: cannot touch '/pgbackup/_writetest': Permission denied
```
`/pgwal`과 마찬가지로 `/pgbackup`도 `root:root 755`라 postgres 계정이 애초에 그 안에 아무것도 쓸 수 없는 상태였다(§12-6에서 `/pgwal`만 고치고 `/pgbackup`은 놓쳤던 것). 아래로 해결했다:
```bash
sudo chown postgres:postgres /pgbackup
ls -ldZ /pgbackup    # 소유자가 postgres postgres로 바뀌었는지 확인
```
(이미 원인을 알고 있다면 위쪽 `touch` 진단은 건너뛰고 `chown`만 해도 된다. §14에서 만든 `pitr_base`는 그대로 두면 된다. 백업 스크립트의 보관 정리는 `appdb_*.dump`, `globals_*.sql`만 대상으로 한다.)

### 15-3. 백업 스크립트 (`/usr/local/bin/pg_dump_backup.sh`)

> 아래는 db02에 실제로 배포된 파일을 `cat`으로 그대로 옮긴 것이다. 처음엔 `/pgbackup/pg_dump_backup.sh`로 뒀다가, 15-4에서 설명하는 이유로 지금 경로(`/usr/local/bin`)로 옮겼다.

> 이 파일을 만드는 명령이 가이드에 빠져 있어 `sudo tee … <<'EOF'` 형태로 넣었다(스크립트 내용은 기존과 동일). 첫 줄부터 `EOF`까지 한 번에 붙여넣는다.

```bash
sudo tee /usr/local/bin/pg_dump_backup.sh > /dev/null <<'EOF'
#!/bin/bash
# db02(Primary) 논리 백업: appdb 데이터 + 전역 객체(role/권한)
# 매일 02:00 systemd timer(pg-logical-backup.timer)로 실행됨. 보관 기간 7일.
set -uo pipefail

BACKUP_DIR=/pgbackup
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=7
LOG_PREFIX="[pg_dump_backup]"

echo "${LOG_PREFIX} 시작: ${DATE}"

/usr/bin/pg_dump -U postgres -F c -f "${BACKUP_DIR}/appdb_${DATE}.dump" appdb
rc_dump=$?

/usr/bin/pg_dumpall -U postgres --globals-only -f "${BACKUP_DIR}/globals_${DATE}.sql"
rc_globals=$?

if [ "${rc_dump}" -ne 0 ] || [ "${rc_globals}" -ne 0 ]; then
  echo "${LOG_PREFIX} 실패: pg_dump rc=${rc_dump}, pg_dumpall rc=${rc_globals}" >&2
  exit 1
fi

echo "${LOG_PREFIX} 완료: appdb_${DATE}.dump, globals_${DATE}.sql"

# ${RETENTION_DAYS}일 지난 백업 자동 삭제
find "${BACKUP_DIR}" -maxdepth 1 -name 'appdb_*.dump' -mtime +${RETENTION_DAYS} -print -delete
find "${BACKUP_DIR}" -maxdepth 1 -name 'globals_*.sql' -mtime +${RETENTION_DAYS} -print -delete

echo "${LOG_PREFIX} 보관 기간(${RETENTION_DAYS}일) 초과분 정리 완료"
EOF
```

```bash
sudo chown postgres:postgres /usr/local/bin/pg_dump_backup.sh
sudo chmod 700 /usr/local/bin/pg_dump_backup.sh
sudo restorecon -v /usr/local/bin/pg_dump_backup.sh
```

재현 기록(2026-10-05): `restorecon -v`는 출력이 없었다(이미 `bin_t`라 바꿀 것이 없음). 위 스크립트 블록을 붙여넣는 동안 터미널 화면에서 마지막 몇 줄이 뒤섞여 보였지만(`exit 1` 아래가 `EOF 초과분 정리 완료…` 같은 조각으로 표시됨), 15-5의 수동 실행에서 `시작`, `완료`, `보관 기간(7일) 초과분 정리 완료`가 모두 출력돼 스크립트가 끝까지 실행된 것은 확인됐다. 화면 표시 문제로 **추정**하며 원인은 **미확인**이다. 파일 끝을 직접 보려면 `sudo wc -l /usr/local/bin/pg_dump_backup.sh`(30줄)와 `sudo tail -6 /usr/local/bin/pg_dump_backup.sh`(마지막 `find` 두 줄과 `echo`)를 쓴다(이번 재현에서는 **미실행**).

### 15-4. systemd service + timer

> 아래도 db02에 실제로 배포된 유닛 파일을 `cat`으로 그대로 옮긴 것이다.

> 두 유닛 파일의 이름과 위치를 알려주는 명령이 가이드에 빠져 있어 `sudo tee … <<'EOF'` 형태로 넣었다(내용은 기존과 동일). 아래 블록 전체를 한 번에 붙여넣는다.

```bash
sudo tee /etc/systemd/system/pg-logical-backup.service > /dev/null <<'EOF'
[Unit]
Description=PostgreSQL logical backup (pg_dump appdb + globals) on db02
After=postgresql.service
Requires=postgresql.service

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/pg_dump_backup.sh
EOF

sudo tee /etc/systemd/system/pg-logical-backup.timer > /dev/null <<'EOF'
[Unit]
Description=Daily PostgreSQL logical backup at 02:00 (db02)

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
```

> 💡 15-3에서 처음부터 `/usr/local/bin`에 스크립트를 만들었다면, 아래 '실제로 겪은 문제'의 **`mv`, `sed` 해결 절차는 필요 없다.** 이 절은 처음 실행에서 스크립트를 `/pgbackup`에 뒀다가 겪은 문제의 기록이다(2026-10-05 재현에서 확인됨: 처음부터 `/usr/local/bin`에 만들었더니 `setenforce 1`(enforcing) 상태의 수동 실행이 성공했다. 해결 절차도 실수로 한 번 실행했는데 `mv`는 `cannot stat '/pgbackup/pg_dump_backup.sh': No such file or directory`였고 `sed`는 바꿀 줄이 없어 변화가 없었을 것이며, 결과에는 영향이 없었다).

**실제로 겪은 문제: 스크립트를 처음엔 `/pgbackup` 안에 뒀다가, `systemctl start`가 조용히 실패**

권한(`chmod 700`, 소유자 `postgres`)은 전부 정확했는데도:
```
Job for pg-logical-backup.service failed because the control process exited with error code.
```
```
Unable to locate executable '/pgbackup/pg_dump_backup.sh': Permission denied
Failed at step EXEC spawning /pgbackup/pg_dump_backup.sh: Permission denied
Main process exited, code=exited, status=203/EXEC
```
이상한 점: **같은 파일을 `sudo -u postgres /pgbackup/pg_dump_backup.sh`로 직접 실행하면 성공**했다. 그리고 `sudo ausearch -m avc -ts recent`로 SELinux 거부 기록을 찾아봐도 **아무것도 안 나왔다.** DAC 권한도, SELinux 감사 로그도 전부 "문제없음"이라고 하는데 정작 systemd로는 실행이 안 되는 모순된 상황이었다.

`setenforce 0`(permissive)로 임시 전환 후 재시도하니 즉시 성공했다. SELinux가 원인이라는 뜻이다. `ausearch`에 기록이 없었던 이유는 Rocky/RHEL의 targeted 정책이 `postgresql_db_t`(데이터 전용 컨텍스트) 안 파일의 실행 거부를 **`dontaudit` 규칙으로 감사 로그 자체를 남기지 않도록** 설계해뒀기 때문이다(데이터 디렉터리 안 파일이 실행되려는 시도 자체를 흔한 오탐/노이즈로 보고 로그를 꺼둔 것). `sudo -u postgres`로 직접 실행했을 땐 성공했던 이유는, 대화형 sudo 세션이 거의 모든 접근이 허용되는 `unconfined_t` 도메인에서 도는 반면, systemd가 유닛을 실행할 때 쓰는 도메인은 그보다 제한적이라 이 정책의 적용을 받았기 때문으로 보인다.

```bash
setenforce 1   # 원상복구
```

**해결**: 스크립트를 데이터 디렉터리 밖으로 옮기고, systemd 유닛의 `ExecStart` 경로만 수정했다(`BACKUP_DIR`은 그대로 `/pgbackup` 유지. 백업 산출물 자체는 데이터 디렉터리에 두는 게 맞다):
```bash
sudo mv /pgbackup/pg_dump_backup.sh /usr/local/bin/pg_dump_backup.sh
sudo chown postgres:postgres /usr/local/bin/pg_dump_backup.sh
sudo chmod 700 /usr/local/bin/pg_dump_backup.sh
sudo restorecon -v /usr/local/bin/pg_dump_backup.sh
# Relabeled /usr/local/bin/pg_dump_backup.sh from ...postgresql_db_t:s0 to ...bin_t:s0

sudo sed -i 's#ExecStart=/pgbackup/pg_dump_backup.sh#ExecStart=/usr/local/bin/pg_dump_backup.sh#' \
  /etc/systemd/system/pg-logical-backup.service
sudo systemctl daemon-reload
```
> 💡 **교훈**: 데이터 전용 SELinux 컨텍스트(`postgresql_db_t` 등 `*_db_t` 계열)가 붙은 디렉터리엔 실행 파일을 두지 않는다. 실행 스크립트는 `/usr/local/bin` 같은 표준 경로(기본 `bin_t`)에 두고, 그 스크립트가 만들어내는 데이터/산출물만 데이터 디렉터리에 저장하는 편이 안전하다. 이 거부는 `dontaudit`로 감사 로그에도 안 남으므로, "권한은 다 맞는데 `203/EXEC`로 실행 자체가 안 됨" 패턴을 보면 `setenforce 0`로 임시 전환해 SELinux 여부부터 확인한다.

### 15-5. 검증

**수동 실행** (timer 활성화 전, enforcing 상태에서 재시도):
```bash
sudo systemctl start pg-logical-backup.service
sudo journalctl -u pg-logical-backup.service --no-pager -n 20
```
✅ 실측:
```
pg_dump_backup.sh[8196]: [pg_dump_backup] 시작: 20260904_154708
pg_dump_backup.sh[8196]: [pg_dump_backup] 완료: appdb_20260904_154708.dump, globals_20260904_154708.sql
pg_dump_backup.sh[8196]: [pg_dump_backup] 보관 기간(7일) 초과분 정리 완료
systemd[1]: Finished pg-logical-backup.service
```

**덤프 무결성 확인** (`pg_restore --list`로 실제 복원 가능한 아카이브인지 확인한다. appdb는 현재 사용자 테이블이 없는 빈 스키마 상태라 TOC 항목이 4개(인코딩 등 메타 정보)뿐인 게 정상이다):
```bash
# 파일명의 타임스탬프는 실행 시각마다 다르므로 가장 최근 파일을 변수에 담아 사용 (v16 r25)
f=$(ls -t /pgbackup/appdb_*.dump | head -1); echo "$f"
sudo -u postgres pg_restore --list "$f"
```
```
; Archive created at 2026-09-04 15:47:08 UTC
;     dbname: appdb
;     TOC Entries: 4
;     Format: CUSTOM
;     Dumped from database version: 16.14
;     Dumped by pg_dump version: 16.14
```

**globals 덤프에 role이 실제로 들어있는지 확인**:
```bash
g=$(ls -t /pgbackup/globals_*.sql | head -1); echo "$g"
sudo grep -E 'CREATE ROLE|ALTER ROLE' "$g"
```
```
CREATE ROLE app_user;
ALTER ROLE app_user WITH ... LOGIN NOREPLICATION ... PASSWORD 'SCRAM-SHA-256$...';
CREATE ROLE postgres;
ALTER ROLE postgres WITH SUPERUSER ...;
CREATE ROLE replicator;
ALTER ROLE replicator WITH ... LOGIN REPLICATION ... PASSWORD 'SCRAM-SHA-256$...';
```

**timer 활성화 + 다음 실행 시각 확인**:
```bash
sudo systemctl enable --now pg-logical-backup.timer
sudo systemctl list-timers pg-logical-backup.timer --no-pager
```
✅ 실측:
```
NEXT                        LEFT LAST PASSED UNIT                    ACTIVATES
Sat 2026-09-05 02:00:00 UTC  10h -    -       pg-logical-backup.timer pg-logical-backup.service
```
`systemctl is-enabled pg-logical-backup.timer` → `enabled` (재부팅 후에도 유지됨).

재현 기록(2026-10-05): 수동 실행 `journalctl`에 `시작: 20261005_141415` → `완료: appdb_20261005_141415.dump, globals_20261005_141415.sql` → `보관 기간(7일) 초과분 정리 완료` → `Finished`가 나왔다. `pg_restore --list`는 `TOC Entries: 4`, `Compression: gzip`, `Dumped from database version: 16.15`(위 예시의 16.14는 처음 실행의 버전)였고, globals에는 `app_user`, `postgres`, `replicator` role 3개가 있었다. `enable --now` 뒤 `list-timers`의 NEXT는 `Tue 2026…`(다음 날 02:00 UTC, 약 11시간 뒤)였는데 터미널 폭 때문에 `…`로 잘려 보였다(`--full`을 붙이면 안 잘린다. systemctl 문서 기준, **미실행**). `is-enabled`는 이번엔 실행하지 않았다. 로그를 문서나 포트폴리오에 올릴 때는 `PASSWORD 'SCRAM-SHA-256$…'` 해시 줄을 가린다.

### 15-6. (참고, 미조치) db01의 기존 §6-9 백업도 같은 문제를 안고 있을 가능성

> 이 절은 처음 실행의 기록이다. §6의 v16 수정(`/pgbackup`을 처음부터 `chown`)을 적용한 재현에서는 db01의 cron이 정상 동작했다. §15-8 참고.

db01의 `/pgbackup`을 확인해보니 여전히 `root:root 755`였고, §6-9에서 등록한 cron(`0 2 * * * /pgbackup/pg_backup.sh`)은 살아있지만 `/pgbackup`엔 `pg_backup.sh` 스크립트 파일만 있을 뿐 `backup_*.dump` 결과물이 하나도 없었다. Phase 1 완료 시점부터 지금까지 매일 밤 조용히 실패해왔을 것으로 추정된다. 이번 작업은 db02(Primary) 범위로 한정했으므로 db01은 그대로 두었다. db01의 이 cron을 고칠지, 아니면 db02 쪽 백업만 신뢰하고 폐기할지는 다음에 결정이 필요하다.

### 15-7. 요약

1. 대상: db02 (Primary)

2. 백업 범위: `appdb`(pg_dump -Fc) + 전역 객체(pg_dumpall --globals-only)

3. 저장 위치: `/pgbackup/appdb_<타임스탬프>.dump`, `/pgbackup/globals_<타임스탬프>.sql`

4. 스크립트 위치: `/usr/local/bin/pg_dump_backup.sh` (데이터 디렉터리 밖. SELinux 문제로 이동)

5. 스케줄: systemd timer, 매일 02:00, `Persistent=true`

6. 보관 기간: 7일 (`find -mtime +7 -delete`)

7. 겪은 문제: ① `/pgbackup` 소유권이 `root:root`(§12-6에서 놓친 부분) ② 데이터 디렉터리 안 실행 파일을 SELinux가 `dontaudit`로 조용히 거부

8. 미조치: db01의 §6-9 백업(같은 문제로 추정, 이번 범위 밖)

### 15-8. db01의 옛 §6-9 백업 cron 폐기: ✅ 완료

> ✅ 15-6에서 "다음에 결정"으로 남겨뒀던 것을 실제로 처리했다.

**진단 (읽기 전용, 5가지 확인)**

🖥️ **db01**에서:
```bash
sudo ls -ldZ /pgbackup
sudo -u postgres crontab -l
sudo cat /pgbackup/pg_backup.sh
sudo ls -la /pgbackup/
sudo find /pgbackup -name 'backup_*.dump'
```
✅ 실측: 15-6의 추정이 전부 그대로 확인됨.
1. `/pgbackup` = `root:root 755`(`postgresql_db_t`). postgres 계정이 쓸 수 없는 상태.
2. crontab에 `0 2 * * * /pgbackup/pg_backup.sh`가 여전히 등록돼 있음(Phase 1 완료일인 8/29부터 약 1주일간 매일 밤 실행 시도).
3. 스크립트 내용은 §6-9 원본 그대로(`pg_dump -F c ... appdb`, 7일 보관).
4. `/pgbackup` 안엔 `pg_backup.sh` 파일 하나뿐, `backup_*.dump` 결과물 0개.
5. (처음 실행) `find / -xdev -name 'backup_*.dump'`로 시스템 전체를 뒤져도 `backup_*.dump`는 어디에도 없음. 8/29 이후 단 한 번도 성공한 적이 없었다는 뜻. **다만 이 해석은 보류한다**: `/pgbackup`은 별도 LV라 `-xdev`가 그 안을 건너뛰므로, 파일이 있어도 이 명령은 빈 결과를 낸다. 위 진단 블록의 명령을 `find /pgbackup …`로 고친 이유다.

> ⚠️ **재현에서는 이 진단 결과가 달랐다.** ① `/pgbackup`은 이미 `postgres:postgres 755`였다(§6의 v16 수정). ② crontab에는 `0 2 * * * /pgbackup/pg_backup.sh`가 있었고 ③ 스크립트 내용은 같았다. ④ `ls -la /pgbackup`에 `backup_20260930_153216.dump`, `…153719`, `20261001_020004`, `20261003_020005`, `20261004_020007`, `20261005_020006` 6개(각 800바이트)가 있어 cron이 **성공**하고 있었다(9/30 15:32, 15:37 두 건은 02:00이 아니므로 수동 실행으로 보이고, 10/2 02:00 파일만 없음. 원인 **미확인**, VM이 꺼져 있었을 가능성). ⑤ `find / -xdev`는 빈 결과였다(위 5번 설명). 그래서 위 1~5는 §6 수정 전 처음 실행의 상태이고, 아래 폐기 결정은 '고장'이 아니라 **중복 제거**가 근거가 된다.

**폐기 결정 근거**

db01은 §13 이후 더 이상 Primary가 아니라 db02의 Standby다. 논리 백업의 정본은 이미 §15의 `pg-logical-backup.timer`(db02, Primary)가 맡고 있으므로, db01에서 같은 일을 하는 이 cron은 고쳐도 중복일 뿐이다. **고치지 않고 폐기**하기로 했다. 단, §13에서 옛 Primary 데이터 디렉터리를 `/pgdata/data.old-primary-YYYYMMDD`로 지우지 않고 보존했던 것과 같은 방식으로, 스크립트 자체는 지우지 않고 흔적만 남겼다.

**실행**

🖥️ **db01**에서:
```bash
sudo -u postgres crontab -r
sudo mv /pgbackup/pg_backup.sh /pgbackup/pg_backup.sh.disabled
sudo chown postgres:postgres /pgbackup
sudo restorecon -v /pgbackup
```
✅ 실측:
```
Backup of postgres's previous crontab saved to /var/lib/pgsql/.cache/crontab/crontab.bak
```
(`crontab -r`이 자동으로 이전 내용을 백업해둠. 별도 조치 불필요)

**결과 확인**
```bash
sudo -u postgres crontab -l
# no crontab for postgres

sudo ls -laZ /pgbackup
# drwxr-xr-x. 2 postgres postgres system_u:object_r:postgresql_db_t:s0 ... /pgbackup
# -rwx------. 1 postgres postgres unconfined_u:object_r:postgresql_db_t:s0 pg_backup.sh.disabled
```
crontab 제거 확인, `/pgbackup` 소유권 `postgres:postgres`로 정리(§16에서 db01이 다시 Primary가 될 경우를 대비해 root:root 버그 자체를 프로젝트에서 없애둠), `pg_backup.sh.disabled`로 흔적 보존까지 전부 확인됐다.

재현 기록(2026-10-05): `crontab -r` → `Backup of postgres's previous crontab saved to /var/lib/pgsql/.cache/crontab/crontab.bak`, `crontab -l` → `no crontab for postgres`, `mv` 뒤 `pg_backup.sh.disabled`(`-rwx------ postgres postgres`, 라벨 `postgresql_db_t`)로 확인됐고 `chown`, `restorecon -v`는 출력이 없었다(이미 맞는 상태). 기존 `backup_*.dump` 6개는 그대로 남아 있다. 예전 cron의 7일 보관 정리가 이제 돌지 않으므로 필요하면 직접 지운다(각 800바이트라 급하지 않음).

---

> ### 🔴 현재 상태 스냅샷 (이어서 작업할 때 먼저 읽는다)
>
> **※ §16(Pacemaker DB HA) 완료 후 갱신됨 (2026-09-09).** §12~§15 시점의 옛 스냅샷은 §16 진행 로그로 대체되었다.
>
> - **db01**: **Primary** (타임라인 45. CP7 스래싱으로 번호가 커졌으나 기능상 무해). `pg_is_in_recovery() = f`. clocksource `tsc`.
> - **db02**: db01의 **Standby로 정상 스트리밍 중**. `pg_is_in_recovery() = t`, TL 45. clocksource `tsc`. `sent_lsn == replay_lsn`.
> - **db-cluster (Pacemaker)**: `pgsqld-clone` Promoted db01 / Unpromoted db02, `db_vip`(10.10.10.23) Started db01. quorum votes 3 (db01 + db02 + qdevice). master score db01=1001 / db02=1000. Failed Actions 없음.
> - **corosync**: `token=10000ms` / `consensus=12000ms` (Option ①). witness01 = `corosync-qnetd`.
> - **앱**: was01/was02가 VIP `10.10.10.23`을 바라봄. `/app/db-check` HTTP 200.
> - **논리 백업**: §16-14에서 `pg-logical-backup`을 **역할 인식형으로 재배포**. db01, db02 양쪽 타이머 `enabled`(매일 02:00 UTC), 실제 백업은 그때그때 Primary인 쪽에서만 수행. (§16-12 To-Do 2, 3 완료.)
> - **`postgresql.service`**: db01, db02 둘 다 **`mask` 영구 유지 결정**(§16-12 To-Do 1). PAF가 `pg_ctl`로 직접 관리하므로 유닛이 필요 없고, 실수로 systemd 경로로 postgres가 뜨는 사고를 차단하는 안전장치.
> - **db01의 옛(구 Primary) 데이터**: `/pgdata/data.old-primary-YYYYMMDD`로 보존 중.
> - **안전장치 스냅샷**: `before-pg-promote-test`(§12), `before-backup-disaster-test`(§14, 6대), `before-corosync-tuning`(§16-10 Phase 0, db01/db02), `before-pgsqld-resource-create`(§16-6 5b 직전).
> - **미결**: 없음. §16-12 To-Do 1~3 완료, ④(CP7 bond0 flapping 근본 대응)는 "향후 과제로 이관"으로 문서화 종결(2026-09-10). §16 항목 자체는 전부 마감. (별개 트랙인 이슈 A 스왑 정책, 이슈 B db02 sysctl harmonize만 여전히 미결.)

---

