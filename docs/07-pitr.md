> 이 문서는 `3tier-rocky10-guide-v16.md` 의 3635~3801줄을 옮겨 공개용으로 문장을 다듬은 것이다. 코드, 명령, 출력, 설정값은 원본 그대로이고, 비밀번호와 로컬 경로만 자리표시자로 바꿨다.

## 14. 논리적 데이터 손실 복구 드릴: PITR(Point-in-Time Recovery)로 DROP TABLE 되돌리기

> ✅ **이 챕터는 실제로 처음부터 끝까지 실행하고 실제 로그로 검증을 마쳤다.**

### 14-1. 목표

§12-6에서 `/pgwal` 소유권 버그를 고치고 "아카이빙 정상"이라고 확인했지만, 그건 `pg_stat_archiver`의 카운터가 올라가는 것만 본 것이지 **그 WAL로 실제 복구가 되는지는 한 번도 증명한 적이 없었다.** 그래서 DROP TABLE 재난 시나리오를 직접 만들어, 백업 시점 이후 데이터(A)는 살아있고 재난 직전 데이터(B)는 없는 상태로 정확히 복구되는지 검증했다.

db02는 계속 실서비스 중이므로, 복구는 **별도 디렉터리(`/pgbackup`), 별도 포트(5433)**의 독립 인스턴스에서 진행해 원본 서비스는 전혀 건드리지 않는 방식으로 설계했다.

### 14-2. Phase A: 백업 뜨고 재난 시나리오 만들기 (✅ 완료)

> **시작 전 확인 (가이드를 읽고 정리한 것이며 실행 전)**: ① db02가 Primary여야 한다(`sudo -u postgres psql -Atc "SELECT pg_is_in_recovery();"` → `f`). ② 아카이빙이 살아 있어야 한다. §12-6 이후 `pg_stat_archiver`의 `failed_count`가 더 늘지 않아야 하며, 그렇지 않으면 아래 복구에 필요한 WAL이 `/pgwal`에 없어 실패한다. ③ db02의 `/pgbackup`이 아직 `root:root`여도(§15-2 전) 아래는 `sudo mkdir` + `chown`으로 하위 디렉터리만 쓰므로 진행에 지장이 없다(2026-10-05 재현: §12-6에서 `/pgbackup`이 `root root`임을 확인한 상태 그대로 §14를 끝까지 진행함).

🖥️ **db02**에서:
```bash
sudo mkdir -p /pgbackup/pitr_base
sudo chown postgres:postgres /pgbackup/pitr_base
sudo -u postgres pg_basebackup -D /pgbackup/pitr_base -Fp -Xnone -P -c fast
sudo restorecon -Rv /pgbackup
```
✅ 실측: `NOTICE: all required WAL segments have been archived` 메시지와 함께 `100%` 완료. `-Xnone`(백업에 WAL 자체를 안 담음)으로 떠서, 이후 복구가 100% `/pgwal` 아카이브에만 의존하도록 설계했다.

```bash
sudo -u postgres psql -c "CREATE TABLE pitr_drill(id serial primary key, note text, t timestamptz default now());"
sudo -u postgres psql -c "INSERT INTO pitr_drill(note) VALUES ('backup 이후 정상 데이터 A');"
sudo -u postgres psql -c "SELECT pg_create_restore_point('before_disaster');"
sudo -u postgres psql -c "INSERT INTO pitr_drill(note) VALUES ('재난 직전 데이터 B - 복구본엔 없어야 정상');"
sudo -u postgres psql -c "DROP TABLE pitr_drill;"
```
✅ 실측: `pg_create_restore_point('before_disaster')` → `0/1202AE28` 반환. `DROP TABLE` 후 `\dt pitr_drill` → "Did not find any relation". 테이블이 실제로 사라진 것 확인.

재현 기록(2026-10-05): `pg_basebackup`이 `NOTICE:  all required WAL segments have been archived`, `30941/30941 kB (100%), 1/1 tablespace`로 끝났고 복구 지점은 `0/E02C7A0`이었다. 위 블록을 한꺼번에 붙여넣으면 `pg_basebackup -P`의 진행 표시가 줄바꿈 없이 끝나 다음 명령(`restorecon`)이 그 줄에 붙어 보여서 실행됐는지 알기 어렵다. 14-3 ①에서 한 번 더 실행하면 된다.

### 14-3. Phase B: 별도 인스턴스로 복구, 실제로 겪은 문제 2건

🖥️ **db02**에서 진행한다. **아래 ①~④ 순서 그대로 하면 이 절 뒤쪽의 '실제로 겪은 문제' 2건을 겪지 않는다**(이 순서로 실행해 둘 다 피했다. 두 문제는 처음 실행 때 사전 확인 없이 진행하다 겪은 기록이다):

**① 라벨 재확인 + 재난 상태 확인**
```bash
sudo restorecon -Rv /pgbackup
sudo -u postgres psql -c '\dt pitr_drill'       # Did not find any relation named "pitr_drill".
```
`restorecon`은 출력이 없으면 정상이다.

**② 복구 지점이 들어 있는 WAL 세그먼트가 `/pgwal`에 아카이브됐는지 확인** (`0/E02C7A0` 자리에는 14-2에서 `pg_create_restore_point`가 출력한 본인의 LSN을 넣는다)
```bash
seg=$(sudo -u postgres psql -Atc "SELECT pg_walfile_name('0/E02C7A0');")
echo $seg
sudo ls /pgwal/$seg          # 'No such file or directory'이면 아래 pg_switch_wal ~ 다음 ls까지 실행, 파일이 보이면 건너뛰어도 됨
sudo -u postgres psql -Atc "SELECT pg_switch_wal();"
sleep 5
sudo ls /pgwal/$seg          # 이제 파일이 보여야 함
sudo -u postgres psql -xc "SELECT last_archived_wal, failed_count FROM pg_stat_archiver;"   # failed_count가 전과 같아야 함
```

**③ 사본 만들기: 권한(`700`)을 복사 전에**
```bash
sudo chmod 700 /pgbackup/pitr_base
sudo cp -a /pgbackup/pitr_base /pgbackup/pitr_restore
sudo restorecon -Rv /pgbackup/pitr_restore
stat -c "%a %U:%G %n" /pgbackup/pitr_base /pgbackup/pitr_restore    # 둘 다 700 postgres:postgres
```

**④ 복구 설정을 넣고 기동**
```bash
sudo -u postgres touch /pgbackup/pitr_restore/recovery.signal
sudo -u postgres tee -a /pgbackup/pitr_restore/postgresql.auto.conf > /dev/null <<'EOF'
restore_command = 'cp /pgwal/%f %p'
recovery_target_name = 'before_disaster'
recovery_target_action = 'pause'
port = 5433
EOF
sudo -u postgres /usr/bin/pg_ctl start -D /pgbackup/pitr_restore -l /tmp/pitr_restore.log
```

**⑤ 기동 확인: 로그 읽기**
```bash
sudo sh -c 'grep -E "restored log file|restore point|pausing|FATAL" /pgbackup/pitr_restore/log/*'
```
이번 복구의 로그는 오늘 날짜 파일(`postgresql-Mon.log` 등)의 마지막 5줄이다:
```
LOG:  restored log file "00000002.history" from archive
LOG:  restored log file "00000002000000000000000D" from archive
LOG:  restored log file "00000002000000000000000E" from archive
LOG:  recovery stopping at restore point "before_disaster", time 2026-10-05 09:16:48.632637+00
LOG:  pausing at the end of recovery
```
> ⚠️ 같은 출력에 `FATAL`이 여러 줄 더 나오는데 **복구 인스턴스의 것이 아니다**. `pg_basebackup`이 db02의 `log/` 폴더를 통째로 복사해 와서 예전 로그(`terminating connection due to administrator command`, §12-4 때의 `could not connect to the primary server … Connection refused` 등)가 함께 검색된다. 시각이 복구 시도 시각(위 예: 09:32)보다 이전이면 무시한다.

아래 '실제로 겪은 문제' 2건은 처음 실행에서 ①~④ 없이 진행하다 겪은 기록이며, 원인 설명은 그대로 유효하다.

**실제로 겪은 문제 1: `mkdir`로 먼저 만든 디렉터리엔 `pg_basebackup`이 권한을 `0700`으로 정정해주지 않음**

첫 시도는 곧바로 실패했다:
```
FATAL:  data directory "/pgbackup/pitr_restore" has invalid permissions
DETAIL:  Permissions should be u=rwx (0700) or u=rwx,g=rx (0750).
```
`stat -c "%a %U:%G %n"`으로 확인해보니 `pitr_base`, `pitr_restore` 둘 다 `755 postgres:postgres`였다. 원인: 14-2에서 `sudo mkdir -p`로 디렉터리를 **미리** 만들었는데, 이건 기본 umask(022)를 따라가 `0755`로 생성된다. `initdb`는 데이터 디렉터리 권한을 알아서 `0700`으로 맞춰주지만, **이미 존재하는 디렉터리에 `pg_basebackup`을 뜨는 경우엔 권한을 건드리지 않는다**(§13에서 새 데이터 디렉터리 만들 때 `chmod 700`을 직접 해준 이유가 바로 이것이었다). 그리고 `cp -a`가 원본 권한을 그대로 보존해, `pitr_restore`에도 `0755`가 그대로 넘어갔다.

```bash
sudo chmod 700 /pgbackup/pitr_base /pgbackup/pitr_restore
```
> 💡 **재발 방지**: 앞으로 데이터 디렉터리 용도로 쓸 디렉터리는 `pg_basebackup`/`cp` 전에 미리 `mkdir` + `chmod 700`을 같이 해두거나, 애초에 `pg_basebackup`이 직접 만들도록 상위 디렉터리만 준비해두는 편이 안전하다.

**실제로 겪은 문제 2: 복구 목표 지점이 하필 아직 아카이브되지 않은 WAL 세그먼트 안에 있었음**

권한을 고친 뒤 재시도하자 `pg_ctl start`는 "stopped waiting / could not start server"로 여전히 실패했지만, 이번엔 `/tmp/pitr_restore.log`에 새로운 FATAL이 안 보였다. 이유는 `logging_collector`가 켜진 서버라 기동 이후 로그가 데이터 디렉터리 안의 `log/`로 옮겨갔기 때문이었다(`sudo`로 그 안의 최신 로그를 다시 열어야 실제 내용이 보인다). 진짜 로그를 열어보니:
```
LOG:  restored log file "000000020000000000000011" from archive
...
cp: cannot stat '/pgwal/000000020000000000000012': No such file or directory
...
FATAL:  recovery ended before configured recovery target was reached
```
세그먼트 `...011`까지는 정상 복원됐는데, 복구 목표 LSN(`0/1202AE28`)이 들어있는 세그먼트 `...012`가 아카이브에 없었다. **WAL 세그먼트(16MB 단위)는 다 차서 다음 파일로 넘어가야만 아카이버에게 전달된다.** 이 드릴처럼 INSERT 한 줄, DROP TABLE 정도의 작업량으론 16MB를 채우기엔 턱없이 부족해, 그 세그먼트는 여전히 db02의 라이브 `pg_wal/`에 "쓰는 중"인 채로 남아있었다. `archive_timeout`도 설정한 적이 없어(기본값 0 = 시간 기준 강제 전환 없음), 자연스럽게 찰 때까지는 계속 그 상태였을 것이다.

```bash
sudo -u postgres psql -c "SELECT pg_switch_wal();"
```
> 💡 **실전 교훈**: 이건 실습만의 문제가 아니라 실제 운영에서도 그대로 나올 수 있는 함정이다. 복구 지점을 찍은 직후 곧바로 재해가 터지면, 그 시점의 WAL이 아직 Primary에만 있고 아카이브엔 없을 수 있다. `archive_timeout`을 적당히(예: 60초) 설정해두면 이런 상황에서 최대 대기 시간을 예측 가능하게 만들 수 있다.

세그먼트를 강제로 넘긴 뒤 재시도하자 정상 진행됐다:
```bash
sudo -u postgres /usr/bin/pg_ctl start -D /pgbackup/pitr_restore -l /tmp/pitr_restore.log
```
✅ 실측 로그: `restored log file "000000020000000000000012" from archive` → `consistent recovery state reached` → `recovery stopping at restore point "before_disaster", time 2026-09-04 06:42:49...` → `pausing at the end of recovery`.

재현 기록(2026-10-05): 위 ②에서 `00000002000000000000000E`가 `/pgwal`에 **없었고**(`No such file or directory`), `pg_switch_wal()`(반환 `0/E031250`) 5초 뒤 생겼으며 `failed_count`는 27 그대로였다. 그래서 복구 지점 세그먼트 미아카이브 문제의 **원인은 이번에도 확인**됐지만, 사전 확인 덕분에 복구 실패 자체는 겪지 않았다. 문제 1(권한 `0755` 거부)은 ③에서 복사 전에 `chmod 700`을 해서 **이번엔 재현하지 않았다**. 그 부분은 처음 실행의 기록이다. 기동은 `server started`였다.

### 14-4. 검증 (✅ 완료)

```bash
sudo -u postgres psql -p 5433 -Atc "SELECT pg_is_in_recovery();"
sudo -u postgres psql -p 5433 -c "SELECT * FROM pitr_drill;"
```
✅ 실측: `pg_is_in_recovery()` → `t`. `pitr_drill` 조회 결과 **정확히 1행**: `id=1, note='backup 이후 정상 데이터 A'`. "재난 직전 데이터 B"는 없고, DROP됐던 테이블 자체는 정상적으로 복구됨. **PITR 완전 검증 성공**.

재현 기록(2026-10-05): `pg_is_in_recovery()` → `t`, `pitr_drill`은 1행(`id=1`, `backup 이후 정상 데이터 A`, `2026-10-05 09:16:44.783004+00`, 복구 지점 시각 09:16:48 이전). 데이터 B는 없고 `DROP`됐던 테이블은 복구됐다. 터미널 폭이 좁으면 표가 줄바꿈으로 깨져 보일 수 있는데 내용과는 무관하다.

> ⚠️ 이 테스트 인스턴스는 promote(`pg_wal_replay_resume()`)하지 않고 `pg_ctl stop`으로 바로 내렸다. promote하면 `archive_command`가 실제 `/pgwal`을 그대로 보고 있어 db02의 진짜 아카이브를 오염시킬 수 있기 때문이다.

### 14-5. 정리

```bash
sudo -u postgres /usr/bin/pg_ctl stop -D /pgbackup/pitr_restore
sudo rm -rf /pgbackup/pitr_restore    # pitr_base는 재사용 가능하니 남겨둠
```

재현 기록(2026-10-05): `pg_ctl stop` → `server stopped`. `ls -l /pgbackup`에는 `pitr_base`(`drwx------ postgres postgres`)만 남았고, 운영 인스턴스는 `pg_is_in_recovery() = f`, `pg_stat_archiver.failed_count = 27`(②와 같은 값)이었다.

### 14-6. 요약

1. **백업 방식**: `pg_basebackup -Xnone`(WAL 미포함). 100% 아카이브 의존 검증
2. **재난 시나리오**: 정상 데이터 A 기록 → 복구 지점 표시 → 재난 데이터 B 기록 → `DROP TABLE`
3. **복구 방식**: 별도 디렉터리, 별도 포트(5433) 독립 인스턴스, `recovery_target_action=pause`로 promote 없이 데이터만 확인
4. **겪은 문제**: ① `mkdir` 후 basebackup → 권한 `0755` 잔존 ② 복구 목표가 미아카이브 세그먼트에 위치
5. **결과**: A만 존재, B는 없음. 목표 지점 정확히 복구됨
