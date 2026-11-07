> 이 문서는 `3tier-rocky10-guide-v16.md` 의 4111~4501줄을 옮겨 공개용으로 문장을 다듬은 것이다. 코드, 명령, 출력, 설정값은 원본 그대로이고, 비밀번호와 로컬 경로만 자리표시자로 바꿨다.

## 16. Pacemaker DB 계층 자동 페일오버 (PAF + corosync-qdevice)

> 이 장은 **실제로 실행하면서 겪은 것**을 시간 순서대로 남긴 기록이다. web/was 계층(§9~§10)의 Pacemaker 구성과 대칭이 되도록 db01/db02에 자동 페일오버를 붙였고, 그 과정에서 만난 문제, 원인, 해결을 체크포인트(CP)별로 정리했다. 뒤이어 페일오버 테스트에서 드러난 네트워크 flapping 문제와, 그 대책으로 진행한 "Option ①"(corosync 타임아웃 상향 + 게스트 clocksource 개선)까지 포함한다.
>
> **결론 먼저**: DB HA 스택은 구축과 검증을 완료했다. 단, 이 실습망(VirtualBox intnet + bond0) 특유의 네트워크 flapping 때문에 "완전 무인 자동 페일오버"는 아직 아니고, 급작스러운 Primary 사망 시 **수동 개입 1회**(`crm_attribute --update`)가 필요할 수 있다(§16-9). Option ①으로 flapping이 멤버십 변경으로 번지는 빈도는 크게 줄였다(§16-10).

### 16-0. 배경: 설계 결정 4가지 (앞서 확정)

1. **클러스터 분리**: db01/db02만의 별도 `db-cluster`를 신설했다. 기존 web-cluster/was-cluster와 완전히 독립시켰다(정책, 쿼럼, 펜싱을 따로 가져가야 하므로).
2. **STONITH 대체**: `stonith-enabled=false` + **`no-quorum-policy=demote`**. 물리 펜싱 장치가 없는 랩이라 완벽한 split-brain 방지는 불가능하지만, 쿼럼을 잃은 쪽 PostgreSQL이 자동으로 강등되게 해 실질 위험을 줄였다. (이 결정의 한계가 CP7에서 그대로 드러났다. §16-8 참고.)
3. **쿼럼 해법**: `corosync-qdevice` + 새 witness VM(`witness01`). Rocky 10 HighAvailability 저장소에 `corosync-qnetd`/`corosync-qdevice`가 실제로 존재함을 확인했다(반면 `sbd`, `fence-agents-*`는 이 저장소에 없음 → 이번 범위 제외).
4. **리소스 에이전트**: **PAF**(`resource-agents-paf`, OCF 이름 `ocf:heartbeat:pgsqlms`). Patroni는 Corosync/Pacemaker를 안 쓰는 다른 아키텍처라 이번 범위에서 제외했다.

### 16-1. 노드 구성

| 노드 | 역할 | 관리망 IP | 서비스망(bond0) IP |
|---|---|---|---|
| db01 | db-cluster 노드1 (nodeid 1) | 192.168.10.113 | 10.10.10.13 |
| db02 | db-cluster 노드2 (nodeid 2) | 192.168.10.114 | 10.10.10.24 |
| witness01 (신규) | corosync-qnetd 전용, 투표권만 | 192.168.10.115 | 10.10.10.25 |
| db_vip | db-cluster 플로팅 IP (§11-2부터 예약) | 없음 | **10.10.10.23** |

- corosync 링(ring0)은 **서비스망 bond0**(`10.10.10.13` / `10.10.10.24`)로 구성했다.
- qdevice↔qnetd 연결은 **관리망**(`192.168.10.115`)으로 붙는다. `host=witness01`이 `/etc/hosts`에서 관리망 IP로 해석되기 때문이다. corosync 링(bond0)과 qdevice 경로(관리망)가 물리적으로 분리되어 **링 장애가 qdevice 연결을 끊지 않는다** → 페일오버 테스트에 유리한 구성이라 **검증 후 의도적으로 유지**하기로 결정했다.

### 16-2. CP1: witness01 VM 추가

- Vagrantfile `NODES`에 `"witness01" => { ip_mgmt: "192.168.10.115", mem: 1024, cpu: 1, extra_disks: [] }` 추가하고 `vagrant up witness01`을 실행했다.
- §3-1~3-4(호스트명, /etc/hosts, 관리망, 기본 도구)를 적용했다. 서비스망 bond0는 기존 노드와 동일 패턴에 IP만 `10.10.10.25/24`로 했다.
- witness01 ↔ db01 ↔ db02 상호 ping 0% loss를 확인했고, 전체 노드 `/etc/hosts`에 `192.168.10.115 witness01`을 등록했다.

### 16-3. CP2: HA 패키지 설치

- 신규 패키지를 §9-3과 동일 절차로 로컬 저장소에 채웠다(다운로드 노드만 아무것도 안 깔린 witness01로 교체). 로컬 저장소는 111→118 패키지가 됐다.
- witness01: `pcs` + `corosync-qnetd`. db01/db02: `pacemaker corosync pcs resource-agents resource-agents-paf corosync-qdevice`.
- 3개 노드 `pacemaker`/`corosync`/`pcs`/`resource-agents` NEVR이 완전히 일치함을 확인했다. hacluster 비번, `pcsd enable --now`, 방화벽 `high-availability`(witness01은 추가로 `5403/tcp`)까지 설정했다.

#### 🔴 실제로 겪은 문제 ①: `pcsd`가 별도 패키지가 아니다

- Rocky 10에서는 `pcsd`가 독립 패키지가 아니라 **`pcs`(0.12.2-3.el10_2.1)에 포함**돼 있다(`/usr/sbin/pcsd`가 `pcs` 소속). draft의 `dnf install ... pcs pcsd ...`는 `No match for argument: pcsd`로 실패해서 설치 목록에서 `pcsd`를 제거했다.

#### 🔴 실제로 겪은 문제 ②: db01에서 `pcsd` 최초 기동 90초 타임아웃

- **증상**: `systemctl enable --now pcsd`가 90초 후 `Result: timeout`으로 끝났다. `journalctl -u pcsd`에 Python `MemoryError` + `multiprocessing` forkserver의 `FileNotFoundError: [Errno 2]`(`SemLock._rebuild`)가 찍혔다.
- **원인(확정)**: db01은 §6-12에서 `vm.overcommit_memory=2`(strict)를 설정했는데 **스왑이 0**이라 `CommitLimit`이 ~1.23 GB(RAM의 50%)뿐이었다. pcsd(Rocky 10)는 Python `multiprocessing` forkserver로 워커를 스폰하는데, strict overcommit에서 `fork()`는 RSS가 아니라 VSZ 전체를 커밋으로 계산하므로, 워커 몇 개 스폰 시 `Committed_AS`가 `CommitLimit` 초과 → 커널이 할당 거부 → `MemoryError` → forkserver 붕괴 → pcsd가 `sd_notify(READY=1)`를 못 보냄 → systemd 타임아웃으로 이어진다. (엔트로피/SSL 문제가 아니다. 커널 6.12는 CRNG가 상시 준비돼 있다.) witness01은 `overcommit_memory=0`(기본)이라 정상이었다.
- **해결**: `rockylinux/10` 박스에 이미 들어있던 `/swapfile`(2 GB, fstab 미등록이라 부팅 시 비활성 상태)을 db01, db02 둘 다 `swapon`하고 `/etc/fstab`에 `/swapfile none swap sw 0 0`을 등록했다. `CommitLimit`이 1.23 GB → 3.28 GB로 늘었다. 이후 db01 `pcsd`는 재기동해 `active (running)`이 됐고, db02 최초 기동도 정상이었다.
- **부수 발견 (이슈 B)**: `diff` 결과 **db02에는 §6-12 커널 튜닝(`/etc/sysctl.d/99-db-tuning.conf`)이 아예 없었다**. §11(db02 스트리밍 복제 구성)이 PostgreSQL 데이터와 설정만 가져왔고 OS 레벨 sysctl은 복제 대상이 아니었기 때문이다. 런타임 드리프트는 4건이었다(`vm.overcommit_memory` 2 vs 0, `vm.swappiness` 10 vs 60, `kernel.shmmax`/`shmall`). → §16-12 To-Do.

### 16-4. CP3: db-cluster 생성

```bash
# 🖥️ db01
sudo pcs host auth db01 addr=192.168.10.113 db02 addr=192.168.10.114 -u hacluster -p <HACLUSTER_PASSWORD>
sudo pcs cluster setup db-cluster db01 addr=10.10.10.13 db02 addr=10.10.10.24   # ring0 = 서비스망 bond0
sudo pcs cluster start --all
sudo pcs cluster enable --all
sudo pcs property set stonith-enabled=false
sudo pcs property set no-quorum-policy=demote
sudo pcs status
```

- 결과: 양노드 Online, DC=db02, Quorate. corosync.conf는 양노드 md5가 동일했다. 이 시점엔 `two_node:1` 모드였다(qdevice를 붙이면 조정된다).

#### 🔴 실제로 겪은 문제: draft의 명령 순서가 틀렸다

- draft는 `pcs property set`을 `pcs cluster start` **전에** 두는데, 그러면 `Error: unable to get cib`가 난다(CIB는 pacemaker가 관리하므로 기동 후에만 접근 가능). **올바른 순서: `cluster start/enable --all` → `property set`.**

### 16-5. CP4: corosync-qdevice 등록

```bash
# 🖥️ witness01
sudo pcs qdevice setup model net --enable --start        # corosync-qnetd, :5403

# 🖥️ db01
sudo pcs host auth witness01 addr=192.168.10.115 -u hacluster -p <HACLUSTER_PASSWORD>
sudo pcs quorum device add model net host=witness01 algorithm=ffsplit
```

- `algorithm=ffsplit`은 `pcs quorum device add --help`로 확인했다. 짝수 노드 클러스터의 기본값이다.
- 결과: Expected votes 2→3, Quorum 1→2가 됐고, `two_node`/`WaitForAll` 플래그가 제거돼 `Quorate Qdevice`가 됐다. corosync.conf에서 `two_node:1`이 삭제되고 `quorum.device` 섹션이 추가됐다(양노드 md5 동일). db01, db02 `corosync-qdevice-tool -s`는 둘 다 `State: Connected`였고, qnetd측은 `Connected clients: 2`, TLS verified였다.

### 16-6. CP5: PAF `pgsqld` 리소스 + `db_vip`

**5a: 사전 정비 (postgres 켜둔 채)**:
- `ALTER SYSTEM SET primary_conninfo`에 `application_name=db01`/`db02`를 추가했다(PAF는 PG12+에서 이걸 필수로 검증한다). auto.conf 중복 라인을 정리했다. db01에도 `db02_slot`을 생성했다(양방향 대비).
- `listen_addresses = '*'`로 설정했다.
- db01 bond0에서 static `10.10.10.23`을 제거했다(`ip addr del` + `nmcli con mod`). db_vip와의 충돌을 막기 위해서이며, 무중단으로 진행했다.
- db01→db02 순차 재시작으로 새 설정을 반영했다(db02 Primary 유지, LSN 일치 확인).
- `systemctl disable postgresql`을 실행했다(**stop은 하지 않았다**. PAF probe가 실행 중 인스턴스를 무재시작 인수하게 하기 위해서다).

**5b: 리소스 생성**. draft §16-10의 문법 오류 3건을 실제 에러로 확인하며 수정했다:

1. draft 원안 `role="Master"` / `"Slave"` → 실제로 필요한 것은 `role="Promoted"` / `"Unpromoted"`. 근거: pcs 0.12.2 / pacemaker 3.x. raw 에이전트 메타데이터는 아직 Master/Slave지만 `pcs resource describe`가 정규화한다.

2. draft 원안 `promotable notify=true` (프리미티브에 부착) → 실제로 필요한 것은 **`pcs resource create --future`** + `promotable meta …` (클론에 부착). 근거: `--future` 없으면 옵션이 프리미티브에 붙어 PAF probe가 `Not installed (You must set meta parameter notify=true for your "master" resource)`를 낸다.

3. draft 원안에는 언급 없음 → 실제로는 `/usr/bin/pg_waldump` 존재가 필요하다. 근거: PAF `validate-all`이 switchover 안전검사(`_check_switchover`)용으로 요구한다. `postgresql-contrib` 소속인데 **db01엔 설치돼 있지 않았다**(db02만 §15때 설치). 그래서 db02(appstream)에서 `postgresql-contrib-16.14` + 의존성 `uuid`를 받아 bond0 http로 db01에 전송한 후 `rpm -i`로 설치했다.

실제로 실행한 최종 명령:
```bash
sudo pcs resource create --future pgsqld ocf:heartbeat:pgsqlms \
  bindir=/usr/bin pgdata=/pgdata/data pgport=5432 \
  op start timeout=60s op stop timeout=60s \
  op promote timeout=30s op demote timeout=120s \
  op monitor interval=15s timeout=10s role=Promoted \
  op monitor interval=16s timeout=10s role=Unpromoted \
  op notify timeout=60s \
  promotable meta promoted-max=1 promoted-node-max=1 clone-max=2 clone-node-max=1 notify=true
```
- 결과: `pgsqld-clone` → **`Promoted: [ db02 ]` / `Unpromoted: [ db01 ]`**. crm_mon 오퍼레이션에 `start`/`promote`가 없었다(`probe`+`monitor`만). 즉 실행 중 인스턴스를 재시작 없이 인수했다. `pg_is_in_recovery`는 db01=t / db02=f로 유지됐다.

**5c: db_vip**:
```bash
sudo pcs resource create db_vip ocf:heartbeat:IPaddr2 ip=10.10.10.23 cidr_netmask=24 op monitor interval=10s --disabled
```
- web_vip/was_vip 컨벤션대로 `nic`은 생략했다(서브넷 자동 감지). 처음엔 `--disabled`로 생성했다.

**5d: 제약**:
```bash
sudo pcs constraint colocation add db_vip with Promoted pgsqld-clone score=INFINITY
sudo pcs constraint order promote pgsqld-clone then start db_vip kind=Mandatory
```
- draft 원안의 `with master`를 `with Promoted`로 바꿨다. `symmetrical`은 기본값(true)이라 "demote 전 db_vip stop"이 자동 추론되므로 별도 demote-path 제약은 필요 없다.
- `pcs resource enable db_vip` → **`db_vip Started db02`**(Promoted 노드)가 됐다. db02 bond0에 `10.10.10.23/24`가 추가됐다.

**5e: Standby conninfo를 VIP로**:
- db01(Unpromoted) `primary_conninfo`의 host를 `10.10.10.24` → `10.10.10.23`(VIP)로 바꿨다. **`ALTER SYSTEM SET primary_conninfo`로 host만 치환**하고(원본 문자열 grep 후 host만 교체, sed로 파일 직접 수정 금지) `SELECT pg_reload_conf()`로 반영했다(재시작 X). walreceiver가 `sender_host=10.10.10.23`으로 재연결됐고, LSN도 일치했다.

### 16-7. CP6: 앱 컷오버

- was01/was02의 `application.properties`에서 `spring.datasource.url` host `10.10.10.13` → `10.10.10.23`(VIP)로 바꿨다. `sed`로 URL 라인만 치환했고(db 이름/포트/user/password 불변), 두 노드 파일 sha256은 동일하다.
- 재시작: was01은 **`sudo pcs resource restart was_tomcat`**으로 했다(systemctl 직접 사용 금지. pacemaker가 실패로 오인한다). was02는 tomcat이 pacemaker에 의해 정지 상태라 설정만 사전에 맞춰 뒀다.

#### 🔴 실제로 겪은 문제: db02 방화벽에 was01/was02용 5432 규칙 누락

- **증상**: was01 tomcat 재시작 후 `/app/db-check` → HTTP 500이 났다. was01에서 `psql -h 10.10.10.23` → `No route to host`가 나왔다(방화벽 거부이고, "connection refused"가 아니다).
- **원인**: db02 방화벽 rich-rule에는 §11-4에서 넣은 **복제용 `10.10.10.13/32`(db01) 하나뿐**이었다. 앱 접근용 `10.10.10.12/32`(was01), `10.10.10.22/32`(was02)는 §6-11 + §10-2-4에서 **db01에만** 추가돼 있었다. db01이 Primary일 땐 문제없었으나 §16으로 db02가 Primary가 되니 앱이 db_vip(=db02) 5432에 못 붙었다. (pg_hba는 §13 basebackup으로 db01 것이 복사돼 이미 허용돼 있었으므로 방화벽만 문제였다.)
- **해결**: db02에 `firewall-cmd --permanent --add-rich-rule 'rule family="ipv4" source address="10.10.10.12/32" port port="5432" protocol="tcp" accept'` + `10.10.10.22/32` 동일 규칙을 추가하고 `--reload`했다.
- **검증**: `/app/db-check`가 500→200이 됐고, access log에서 전환 시점을 확인했다. db02 `pg_stat_activity`에 `app_user@10.10.10.12` idle 커넥션 10건(HikariPool)이 보였다.
- **교훈**: **DB HA에서는 두 DB 노드의 5432 방화벽 규칙을 역할 기준으로 대칭 구성**해야 한다. 어느 쪽이 Primary가 되든 앱/복제가 동일하게 붙어야 하기 때문이다. 각 노드가 `was01 + was02 + 상대 DB 노드`를 허용하면 된다(자기 IP 규칙은 불필요).

### 16-8. CP7: 페일오버 테스트, 자동 페일오버 실패

**시나리오**: db02(Primary)를 하드 poweroff(2026-09-07 ~09:56 UTC) → db01이 사람 개입 없이 자동 승격되는지 확인했다.

**결과: 자동 승격이 되지 않았다. 앱은 1시간+ 다운됐다.**

**타임라인과 근본 원인**:
1. **bond0/intnet 네트워크가 종일 flapping했다**. corosync 멤버십 churn이 다수 발생했고, `"Resetting MTU because host 2 joined"`가 반복됐다.
2. 09:49:13 UTC에 **2초짜리 corosync 파티션**이 발생했다. pacemaker가 db01을 **spurious 승격**했고(TL2→TL3, 09:49:15), db02가 2초 후 복귀하자 pacemaker가 db01을 **demote**했다(09:49:18).
3. **demote 후 db01이 영구 고장 났다**: PAF의 demote는 `pg_rewind`를 하지 않는다. 그래서 db01은 TL3인 채로 db02(TL2)를 standby로 따라가려다 `FATAL: highest timeline 2 of the primary is behind recovery timeline 3`를 무한 반복했다. 09:49~09:56 사이 db02가 정상 Primary였지만 db01은 복제가 완전히 끊긴 상태였다.
4. db02의 Promoted monitor가 db01을 "not connected"로 정확히 판단해 `master-pgsqld = -1000`을 설정했다(정당한 값이고 stale이 아니다).
5. 09:56 db02가 실제로 죽자 pacemaker는 db01(score `-1000`)을 승격을 거부했고, `"Promoted 0 instances"`가 반복됐다.

**드러난 두 가지 맹점**:
- **PAF Unpromoted monitor의 한계**: db01의 timeline FATAL 루프를 감지하지 못하고 계속 "healthy Unpromoted"로 보고했다. `pcs status`상으로는 정상처럼 보였다.
- **STONITH 없는 설계의 실증적 한계**: 펜싱이 있었다면 09:49 blip에서 소수파가 fence(kill)돼 split이 회피됐을 것이다. `stonith-enabled=false`(펜싱 HW 없음)가 이 시나리오의 실질 취약점이다.

### 16-9. CP7 복구: 데이터 손실 0, 수동 개입으로 Primary 복원

**데이터 손실 검증 → ZERO**:
- db02 `pg_controldata`: state `in production`, TL **2**, 마지막 checkpoint `0/140021A8` @ 03:50 (`pg_control last modified`도 03:50. 6시간+ 변경이 없었다 = write 전무). `00000003.history`는 없었다.
- db02 `pg_waldump`(checkpoint REDO~끝): `RUNNING_XACTS` 2건 + `CHECKPOINT_ONLINE` 1건뿐이었고, `nextXid`는 757로 고정돼 있었다. **db02 WAL은 정확히 `0/14002258`에서 끝났다**. db01이 TL3로 fork한 바로 그 지점이다.
- db01: TL2 WAL을 `0/14002258`까지 replay를 완료한 후 spurious 승격됐으므로 **db01이 db02의 모든 커밋 데이터를 보유**하고 있다. 09:49~09:56 창에는 db02 write가 하나도 없었다(앱 `/app/db-check`는 SELECT만).
- ⚠️ 이 "손실 0"은 **앱이 read-only였기 때문**이다. 운영 환경(쓰기 트래픽 있음)에서는 fork~crash 구간의 커밋이 유실될 수 있다.

**복구 절차 (A안)**:
1. `pcs resource cleanup pgsqld-clone` → 실패 op 이력은 지워지지만 **`master-pgsqld=-1000`은 지워지지 않는다**(cleanup은 failcount만 건드린다).
2. `crm_attribute -N db01 -l forever -n master-pgsqld --delete` → 삭제된다. 하지만 점수가 없으니 pacemaker가 승격하지 않는다(양수 점수 필요).
3. `crm_attribute -N db01 -l forever -n master-pgsqld --update 1000` → **db01 승격을 트리거**한다. PAF Promoted monitor가 `_check_locations`로 점수를 1001로 자가보정한다. 결과는 `Promoted: [ db01 ]`, `db_vip Started db01`, `pg_is_in_recovery=f`, TL **3→4**였다.
4. `/app/db-check` HTTP 200을 재확인했고, HikariPool도 재확립됐다.

**db02 재합류: `pg_rewind` 시도 실패 → `pg_basebackup` 폴백**:
- `pg_rewind` 자체는 `Done!`(exit 0, fork 지점 `0/14002258` 정확 감지)까지 됐으나, 그 다음 `pg_ctl start`에서 `FATAL: according to history file, WAL location 0/15000000 belongs to timeline 3, but previous recovered WAL file came from timeline 4`가 났다.
- **원인**: db02를 "clean shutdown을 만들려고" standalone으로 기동했더니 db02가 자기 Primary(TL2)로 돌면서 fork 지점 이후 TL2 WAL을 새로 썼다. pg_rewind가 되돌리긴 했지만, 로컬 pg_wal의 stale full segment + TL3 bridge segment가 db01 아카이브에만 존재 + db02에 `restore_command` 미설정이 겹쳐 타임라인 전환 recovery가 실패했다. 실패한 start가 `backup_label`을 소비(`.old`로 rename)해 재시도도 막혔다.
- **해결**: `/pgdata/data`를 완전히 비우고 **`pg_basebackup -h 10.10.10.23 -U replicator -X stream -R -S db02_slot`**을 실행했다(§13의 결론 재확인: 이 프로젝트 환경에선 pg_basebackup이 답). basebackup이 db01의 auto.conf를 복사하고 `-R`이 라인을 추가하는 방식이라 stale 라인(`primary_slot_name='db01_slot'`, `application_name=db01`)이 섞였다. **postgres 정지 상태이므로 `sed`로 직접 편집**했다(실행 중이었다면 `ALTER SYSTEM`을 썼을 것이다).
- db02 `pg_ctl start` → `started streaming WAL from primary ... on timeline 4`. `systemctl enable --now corosync pacemaker` → `pcs resource cleanup` → **pacemaker가 수동 기동 인스턴스를 재시작 없이 인수**했다. 최종 `pcs status`: `Promoted: db01 / Unpromoted: db02`, `db_vip Started db01`, master score db01=1001/db02=1000, 앱 200.

**CP7 최종 상태**: 역할이 §16 시작 시점과 **반대로** 바뀌었다. db01=Primary(TL4), db02=Standby.

**CP7 핵심 교훈 (반드시 기억)**:
- ① **자동 페일오버가 자동으로 되지 않는다**: bond0 flapping이 만든 spurious promote/demote로 생존 노드 score가 `-1000`으로 굳고, Primary 사망 후엔 score를 새로 매겨줄 노드가 없다(PAF는 "현재 Primary인 노드"만 master score를 설정한다). `pcs resource cleanup`도 score를 건드리지 않는다. → **수동 `crm_attribute --update <양수>` 개입이 필요하다.**
- ② PAF의 Unpromoted monitor는 timeline-broken standby를 "healthy"로 오보고한다.
- ③ pg_rewind 타깃을 "clean shutdown 만들려고" standalone 기동하면 더 꼬인다. 아카이브 접근/`restore_command` 없이는 타임라인 전환 recovery가 안 된다. → **pg_basebackup이 답.**
- ④ **근본 원인은 네트워크 flapping이다**. 대책 없이는 재발한다. → §16-10.

### 16-10. Option ①: bond0 flapping 대책, corosync 타임아웃 상향 + 게스트 clocksource 개선

**진단**: SBD/펜싱(diskless softdog)도 검토했으나 이 환경에는 리스크가 있다(flappy 망에서 blip마다 self-reboot, db02 시계 불안정으로 false-trigger). **먼저 리부팅 리스크 0인 Option ①**(corosync 타임아웃 상향 + clocksource 안정화)부터 적용하기로 결정했다.

- corosync knet 기본값: `token=3000ms`, `consensus=3600ms`. → ~1.5~3초 링크 끊김이면 멤버십 변경이 트리거된다.
- 게스트 clocksource: 양 DB 노드 모두 `acpi_pm`이었다(커널이 TSC를 `unstable`로 마킹해 제거했다. VirtualBox의 고질적 문제다). db02 chrony RMS offset은 **267 ms**(db01은 0.19 ms)로 매우 불안정했다. 이는 corosync 타이밍 판단에 악영향을 주며, CP7의 "시계 튐"과도 일치한다.

#### Phase 0: baseline + qdevice 재기동

- VBox 스냅샷 `before-corosync-tuning`(db01/db02)을 떴다. baseline은 token 3000 / consensus 3600, 복제 정상, 앱 200이었다.
- 🔴 **발견**: db02의 `corosync-qdevice` 서비스가 `inactive`였다(enabled지만 미기동. CP7 재합류 때 corosync/pacemaker만 enable하고 qdevice는 빠뜨렸다). `pcs quorum status`에서 db02가 `NR`(Not Registered)로 나왔다. 클러스터는 db01의 qdevice 연결로 votes 3을 유지 중이었으나, **Phase 3에서 db02가 단독일 때 qdevice 표를 못 받아 inquorate 될 위험**이 있어 `systemctl start corosync-qdevice`(db02)로 먼저 해결했다. 이후 db02 플래그는 `NR` → `A,V,NMW`로 바뀌었다.

#### Phase 1: corosync `token` 3000→10000 / `consensus` 3600→12000 (무중단)

```bash
# 🖥️ db01 (양노드에 자동 sync)
sudo pcs cluster config update totem token=10000 consensus=12000
# 이어서 텀 없이
sudo pcs cluster reload corosync    # db01
# 🖥️ db02
sudo pcs cluster reload corosync
```
- 검증: 양노드 `corosync-cmapctl | grep runtime.config.totem.token` = 10000, `consensus` = 12000이었다. corosync.conf md5도 동일했다. **VM 재부팅 없이 reload만으로 런타임에 반영됐다.**
- reload 직후 `pcs status`는 정상이었고, corosync.log에 `processor failed` / `A new membership` / token-timeout은 **0건**이었다.
- 참고: 직전 flapping의 마지막 멤버십 변경은 구 3000ms 토큰 시절이었고, reload 후 관찰된 `"Token has not been received in 2251 ms"` notice는 10000ms 미만이라 멤버십 변경으로 번지지 않았다. **정확히 이 마진 blip을 흡수하려는 것이다.**

#### Phase 2: db02(Standby) 게스트 clocksource 개선

`--paravirtprovider`는 VM 전원 OFF 상태에서만 바꿀 수 있으므로:
```bash
# 🖥️ db01
sudo pcs property set maintenance-mode=true      # 리소스 unmanaged (역할·VIP는 그대로 유지)
sudo pcs cluster stop db02                        # 노드명 명시
# 🖥️ 호스트 PC
vagrant halt db02
& $vbm modifyvm 3t-r10-db02 --paravirtprovider kvm   # legacy/none → kvm/kvm
vagrant up db02
```
- **결과: clocksource `acpi_pm` → `tsc`** (kvm-clock이 아니다). `--paravirtprovider kvm`이 KVM 파라버추얼 인터페이스로 TSC 주파수/invariant 정보를 게스트에 노출하므로, 커널이 더 이상 `"Marking TSC unstable"` 하지 않고 TSC(가장 높은 rating)를 선택한다. **kvm-clock도 `available_clocksource` 목록에 생겼다** → 나중에 TSC가 unstable 판정을 받아도 `acpi_pm`이 아니라 kvm-clock으로 폴백된다. tsc는 kvm-clock보다 읽기 오버헤드가 낮고 정밀하므로 사실상 최선의 결과다.
- **db02 chrony RMS: 267 ms → 6 ms**(부팅 8분 시점)였고, 이후 수렴했다.
- db02 재합류를 확인한 후 `sudo pcs property set maintenance-mode=false`를 실행하자 pacemaker가 db02 pgsqld를 Unpromoted로 자동 재기동했고, streaming도 재개됐다(`sent_lsn == replay_lsn`).
- **결정**: `clocksource=tsc`를 최종값으로 수용했다. GRUB 커널 파라미터(`clocksource=`)는 건드리지 않았다.

#### Phase 3: db01(Primary) 게스트 clocksource 개선

**처음엔 A안(무중단 스위치오버)을 시도했다가 실패했고, 스래싱 끝에 복구했다.** 반드시 남겨야 할 트러블슈팅:

- `pcs resource move pgsqld-clone db02 --promoted`를 실행했다. pcs 0.12는 이 명령이 **동기 대기**(내부 타임아웃 ~1h)하며 `cli-prefer-pgsqld-clone` **INFINITY** location 제약을 만든다.
- **PAF가 스위치오버를 반복 취소했다**: `pgsqld promote on db02 ... 'Switchover has been canceled from pre-promote action'`. 원인은 PAF `_check_switchover` 안전검사다. 승격 대상(db02)의 수신 LSN이 구 Primary(db01)의 pre-demote LSN에 도달해야 하는데 계속 **정확히 WAL 1세그먼트(16 MB) 뒤처졌다**. async 복제 + idle 워크로드(WAL이 체크포인트/승격 때만 세그먼트 경계로 점프) + 재승격마다 db01이 또 한 세그먼트 전진하므로 db02가 레이스에서 영원히 진다.
- **INFINITY 제약이 자동으로 지워지지 않아 ~4.5시간 파괴적 스래싱이 일어났다**: db01이 promote→demote→shutdown(shutdown checkpoint ~60s)→standby 재기동→재승격을 분당 1회꼴로 반복했다. 매 사이클 db_vip가 stop/start됐다. 타임라인이 **4 → 44**까지 올라갔다(약 40회 bump. 단, db01, db02는 항상 일치했고 분기나 손실은 없었다).
- **복구**: `pcs resource clear pgsqld-clone`(제약 제거) → 40초 내 `Promoted: db01 / Unpromoted: db02 / db_vip db01`로 복귀했다. `pcs resource cleanup pgsqld`로 failcount를 정리했다.
- ✅ **부수 확인**: 이 4.5시간 스래싱(pacemaker 리소스 대량 churn) 내내 corosync.log에 `processor failed`/`A new membership`/token-timeout **0건**이었다. **Phase 1의 token=10000이 실전에서 검증됐다**.
- **결론**: **A안(`pcs resource move --promoted`)은 이 환경에서 쓰면 안 된다**. 실패 시 INFINITY 제약이 스래싱을 유발한다. **다시는 시도하지 말아야 한다.**

**대신 B안 (다운타임 ~2분 감수, 역할 전환 없음)**:
```bash
# 🖥️ db01
sudo pcs property set maintenance-mode=true
sudo pcs cluster stop db01                        # 노드명 명시
sudo -u postgres pg_ctl stop -D /pgdata/data -m fast -w -t 120   # (아래 주의 참고)
# 🖥️ 호스트 PC
vagrant halt db01
& $vbm modifyvm 3t-r10-db01 --paravirtprovider kvm
vagrant up db01
# 재합류·검증 후
sudo pcs property set maintenance-mode=false
```

- 🔴 **주의: postgres를 명시적으로 내려야 한다**. db01/db02의 PostgreSQL은 **systemd(`postgresql.service`)가 아니라 PAF가 `pg_ctl`로 직접 기동**한다. `postgresql.service`는 `disabled`이고 cgroup도 `pacemaker.service` 소속이다. `pcs cluster stop`은 클러스터 데몬만 멈추고 postgres는 건드리지 않으므로, `vagrant halt`에만 맡기면 systemd가 SIGTERM(smart shutdown)으로 애매하게 끝날 수 있다. → **halt 전에 `pg_ctl stop -m fast`로 직접 정상 종료**시키고 로그에서 `"database system is shut down"`을 확인한다.
- `maintenance-mode=false` 직전에 양노드 `pg_controldata`로 TL/checkpoint LSN이 일치하는지 재확인했다(이번엔 둘 다 TL 44, checkpoint `0/40000028`로 일치했다. db02가 db01의 shutdown checkpoint까지 replay를 완료해 갭 0).
- **결과**: db01도 clocksource가 `acpi_pm` → `tsc`로 바뀌었고, `"Marking TSC unstable"`은 없으며, `available`에 kvm-clock이 등록됐다. db01, db02 대칭을 확보했다.

#### 🔴 Phase 3에서 겪은 문제 ①: `maintenance-mode=false` 직후 promote 1회 꼬임 (동시 콜드부팅 레이스)

- **증상**: `maintenance-mode=false`(03:59) 직후 `Failed Resource Actions` 2건이 떴다. `pgsqld promote on db01 could not be executed (Timed out ... within 30s)`, `pgsqld promote on db02 ... 'Can not get current node LSN location'`.
- **원인**: db01, db02가 **둘 다 정지 상태에서 거의 동시에 부팅**된 비정상 상황이었다(보통은 한 노드씩 재부팅). pacemaker 첫 스케줄러 실행이 start 순서 완료 전에 promote를 시도했고, RA가 블록돼 30초 후 강제 종료됐다. pacemaker가 재계산 후 start→promote를 깨끗이 성공시켰다(**실제 성공한 promote는 318 ms**). 04:00:18에 db02가 재연결되며 score `-1000` → `1000`으로 자동 정정됐다. **CP7 스래싱과는 무관한 1회성 레이스였고, 자체 수렴했다.**
- **해결**: 재발 대비 + 향후 페일오버 테스트 노이즈 감소를 위해 op 타임아웃을 상향했다:
  ```bash
  sudo pcs resource update pgsqld op promote interval=0s timeout=60s   # 30s → 60s
  sudo pcs resource update pgsqld op start   interval=0s timeout=90s   # 60s → 90s
  ```
  나머지 op(demote 120 / stop 60 / monitor 10 / notify 60 / reload 20)는 손대지 않았다. CIB 재조회로 op id 재사용(중복 없음)을 확인한 후 `pcs resource cleanup pgsqld`를 실행하자 `Failed Resource Actions`, `Migration Summary`가 비워졌고, 역할은 유지됐으며 master score는 db01=1001/db02=1000이었다.

#### 🔴 Phase 3에서 겪은 문제 ②: db02 postgres가 부팅 시 systemd로 딸려 올라왔다

- **증상**: `vagrant halt` 전에 `pg_ctl stop`으로 깨끗이 내렸는데, `vagrant up db02` 후 postgres가 이미 떠 있었다(cgroup이 `pacemaker.service`가 아니라 `postgresql.service`).
- **원인**: `postgresql.service` 자체는 `disabled`지만, **§15의 `pg-logical-backup.timer`가 `Persistent=true`**라서 VM이 꺼져 있던 02:00 실행을 부팅 시 catch-up했고, `pg-logical-backup.service`가 `Requires=postgresql.service`이므로 systemd가 postgres를 의존성으로 시작했다. db01에는 이 타이머가 없어서(§15는 db02만) 이런 현상이 없었다. 즉 **두 노드 설정 드리프트**다.
- **조치**: 양 DB 노드에 `systemctl mask postgresql.service`, db02에 `systemctl stop pg-logical-backup.timer`를 실행했다. PAF는 `pg_ctl`을 직접 호출하므로 mask의 영향을 받지 않는다(systemctl 경로만 차단). → 이후 **mask는 영구 유지로 확정**했고(§16-12 To-Do 1), 백업 타이머는 역할 인식형으로 재배포했다(§16-14).

### 16-11. 마무리: chrony/NTP 진단, web/was 계층 순차 기동

**chrony가 "미동기화"로 보였지만 정상이었던 건**:
- Phase 3 직후 db01에서 `timedatectl` → `System clock synchronized: no`, `chronyc tracking` → `Leap status: Not synchronised`(Stratum 0, RMS 0)였다.
- **원인은 설계상 의도된 것**: 이 폐쇄망의 내부 NTP 소스는 **web01**(`/etc/chrony.conf`에 `server web01 iburst` 한 줄뿐)인데, web/was 계층을 아직 부팅하지 않아 web01이 꺼져 있었을 뿐이다. `chronyc sources`에는 `^? web01 ... Reach 0`(도달 불가)이 보였다.
- web01을 올리자 즉시 `^* web01`(Stratum 4)로 동기화됐고, db01 **RMS offset 0.26 ms**, `System clock synchronized: yes`가 됐다. clocksource는 `tsc`를 유지했다.
- **교훈**: 폐쇄망에서 DB 노드만 재부팅한 뒤 chrony가 미동기화로 보여도 당황할 필요가 없다. 내부 NTP 소스(web01)가 살아있는지부터 확인하면 된다.

**web/was 계층은 반드시 한 대씩 순차로 기동**:
- `web01 → web02 → was01 → was02` 순서로 하나씩 `vagrant up`하고, 각 VM SSH 접속을 확인한 후 다음으로 넘어갔다. 각 ~75초가 걸렸다.
- **네 대를 동시에 올리면 안 된다**: 이 VirtualBox 중첩 가상화 환경은 호스트 리소스 한계가 있어서, 동시 콜드부팅은 §16-10 Phase 3에서 겪은 것과 같은 타이밍 레이스/지연을 유발할 수 있다.
- ⚠️ **`vagrant status`가 타임아웃 나도 VM은 정상일 수 있음**: was02 기동 직후 `vagrant status`가 6분+ 응답이 없었으나, `VBoxManage list runningvms`로 확인하니 7대 전부 running, SSH 정상이었다. `vagrant status`는 7대 VBox 상태를 순차 조회하느라 부하 시 느려지는 알려진 현상이다. VM 상태 확인은 `VBoxManage list runningvms`가 빠르고 확실하다.

**최종 검증**:
- 앱: web01에서 `curl http://localhost/app/db-check` → HTTP 200, `"DB 연결 성공: appdb"`. (web01 → VIP `10.10.10.23` → 현재 Primary db01.)
- 복제: db01(Primary, `pg_is_in_recovery=f`, TL 45) ← db02(Standby, `=t`, TL 45) streaming, `sent_lsn == replay_lsn`.
- Windows 브라우저 접속: web01 `http://192.168.10.111/`, web02 `http://192.168.10.121/` (Vagrantfile은 `private_network`(host-only) IP만 부여, HTTP `forwarded_port` 없음).

### 16-12. 남은 작업 (To-Do)

1. ~~**db01, db02 `postgresql.service` mask 해제 재검토**~~: ✅ **결정 완료 (2026-09-09): mask를 영구 유지, unmask하지 않는다.**
   - **근거 ①**: PAF(`ocf:heartbeat:pgsqlms`)는 systemd를 거치지 않고 `pg_ctl`을 직접 호출해 PostgreSQL을 기동/정지/승격한다. 실제로 두 노드의 postgres 프로세스는 cgroup `system.slice/pacemaker.service` 아래에 있고 `postgresql.service`는 `inactive`다. 즉 **`postgresql.service` 유닛이 살아있을 필요 자체가 없다.**
   - **근거 ②**: mask는 안전장치다. `postgresql.service`가 `/dev/null`로 마스킹돼 있으면, 사람이 습관적으로 `systemctl start postgresql`을 입력하거나 다른 자동화 스크립트가 실수로 systemd 경로로 postgres를 띄우는 것을 **원천 차단**한다. 이게 없으면 PAF가 관리하는 인스턴스와 별개의 postgres 프로세스가 동시에 떠서 **포트 충돌**, 최악의 경우 **동일 데이터 디렉터리 이중 접근**이라는 사고로 이어질 수 있다.
   - 확인(2026-09-09): db01, db02 둘 다 `systemctl is-enabled postgresql.service` → `masked`, `is-active` → `inactive`, 심볼릭 링크 `/etc/systemd/system/postgresql.service -> /dev/null`. PAF 관리 postgres는 정상 기동 중(cgroup `pacemaker.service`).
   - 부수 영향: §16-14의 `pg-logical-backup.service`에서 `Requires=postgresql.service`를 뺀 것도 이 결정의 연장선이다. 백업 유닛도 systemd의 postgresql.service에 의존하지 않고 스스로 역할을 판단한다.
2. ~~**db02 `pg-logical-backup.timer` 재가동**~~: ✅ **완료 (2026-09-09, §16-14)**. 타이머는 두 노드 모두 `enabled` + `active`, 다음 실행 매일 02:00 UTC.
3. ~~**db01에 §15 논리 백업 자동화 없음 (노드 설정 드리프트)**~~: ✅ **완료 (2026-09-09, §16-14)**. 스크립트를 **역할 인식형**으로 고쳐(`pg_is_in_recovery()` 확인 → Standby면 건너뛰고 exit 0) db01, db02에 동일하게 배포했다. 두 노드 다 타이머를 켜둬도 실제 백업은 그때그때 Primary인 쪽에서만 수행된다.
4. **CP7 bond0 2초 blip → spurious promote/demote 이슈**: 🔵 **문서화 완료, 향후 과제로 이관 (2026-09-10)**
   - **결론: 지금 단계에서는 구현하지 않는다.** 알려진 한계(known limitation)로 명시하고 향후 과제(future work)로 남긴다.
   - **근거 ①: Option ①로 이미 실질적 충분선에 도달**. §16-10에서 corosync `token`/`consensus` 상향(3000→10000ms / 3600→12000ms) + 게스트 clocksource 안정화(`acpi_pm`→`tsc`)를 적용한 뒤, 4.5시간의 격렬한 pacemaker 리소스 스래싱 중에도 spurious 멤버십 변경이 **0건**이었다(§16-10 Phase 3 실측). bond0/intnet이 물리적으로 flapping하는 것 자체는 남아있지만, **그게 spurious promote/demote로 번지는 경로는 사실상 막혔다.** 포트폴리오, 데모 목적의 폐쇄망 랩 환경 기준으로는 이 정도면 충분한 수준으로 판단한다.
   - **근거 ②: 근본 해결책 후보 3가지가 전부 득보다 실이 큼** (현재 단계 기준). 후보별 리스크와 공수:
     - (a) diskless SBD(softdog) 펜싱: 쿼럼을 잃은 노드가 watchdog 타임아웃 후 **self-reboot**. flappy 망에서는 blip마다 재부팅돼 오히려 가용성을 해칠 수 있다(§16 앞부분 SBD 조사 결과).
     - (b) `pg_rewind` 자동화 래퍼: PAF가 지원하지 않는다. 안전한 승격/재합류 판단 로직을 **직접 구현**해야 하고, 잘못 만들면 CP7보다 더 심각한 사고(자동 split-brain 해소 실패)가 날 수 있다.
     - (c) intnet → 다른 네트워크 백엔드: corosync 링 자체를 바꾸는 **네트워크 계층 전면 교체**다. 영향 범위가 db-cluster를 넘어 전체 인프라에 미친다.
   - **실제 프로덕션 환경이라면**: 예산과 인력이 있다면 **(a) diskless SBD(또는 공유디스크 SBD) 펜싱이 가장 표준적인 접근**이다. pacemaker HA 스택의 정석적인 펜싱 방식이고, watchdog 타임아웃과 네트워크 안정성을 충분히 검증한 뒤 적용하는 것이 정공법이다.
   - (관련 미결 항목: §16-3 이슈 A 스왑 정책, 이슈 B db02 sysctl 튜닝(`99-db-tuning.conf`) harmonize. 이 둘은 bond0 flapping 대응과 별개 항목으로 여전히 미결이다.)

### 16-13. 요약

1. 클러스터: `db-cluster` (db01 nodeid1 / db02 nodeid2), ring0 = 서비스망 bond0

2. 쿼럼: `corosync-qdevice` + witness01(`corosync-qnetd`, ffsplit). 경로는 관리망(링과 분리, 의도적)

3. 펜싱: `stonith-enabled=false` + `no-quorum-policy=demote` (펜싱 HW 없는 랩)

4. 리소스: `pgsqld-clone`(PAF `ocf:heartbeat:pgsqlms`, promotable) + `db_vip`(IPaddr2 `10.10.10.23`)

5. op 타임아웃: start 90s / stop 60s / **promote 60s**(기본 30s에서 상향) / demote 120s / monitor 10s

6. 앱 연동: was01/was02 `spring.datasource.url` → `10.10.10.23`(VIP). 두 DB 노드 5432 방화벽을 역할 대칭 구성

7. clocksource: 양 DB 노드 `acpi_pm` → **`tsc`** (VBox `--paravirtprovider kvm`). kvm-clock은 폴백으로 확보

8. corosync: `token` 3000→**10000ms**, `consensus` 3600→**12000ms** (reload로 무중단 반영)

9. 자동 페일오버: **부분적**. 급작스러운 Primary 사망 시 수동 `crm_attribute --update <양수>` 1회 필요할 수 있다(§16-9 ①). Option ①으로 spurious 멤버십 변경 빈도는 대폭 감소

10. 데이터 안전: CP7에서 손실 0 확인(단, 앱이 read-only였던 덕. 운영에선 다를 수 있다)

11. 논리 백업: §15의 `pg-logical-backup`를 **역할 인식형으로 재배포**(§16-14). db01, db02 양쪽 타이머 `enabled`, 실제 백업은 Primary인 쪽에서만

12. postgresql.service: db01, db02 모두 **`mask` 영구 유지**(§16-12 To-Do 1 결정). PAF가 `pg_ctl`로 직접 관리 + 실수로 systemd 경로로 postgres가 뜨는 사고 차단

13. 미결: **실질 미결 없음**. §16-12 To-Do 1~3 완료, ④(bond0 flapping 근본 대응)는 "향후 과제로 이관" 결정(2026-09-10)으로 문서화 종결. Option ①로 실질 충분선 도달 판단, 근본 해결책 3안은 득보다 실이 커 보류

### 16-14. 논리 백업 자동화를 역할 인식형으로 재배포 (To-Do 2, 3 해소)

§15의 `pg-logical-backup`(스크립트 + systemd service/timer)은 db02에만 있었고, §16-10 Phase 3에서 타이머를 꺼둔 상태였다. CP7 이후 db01/db02 역할이 상황에 따라 바뀌므로, **"Primary가 어느 쪽이든 그 노드에서 백업이 도는"** 구조로 다시 만들었다.

**바뀐 점: 스크립트 맨 앞에 역할 확인만 추가** (기존 `pg_dump`/`pg_dumpall`/보관기간 정리 로직은 한 줄도 안 건드림):
```bash
in_recovery=$(/usr/bin/psql -U postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]')
if [ "${in_recovery}" = "t" ]; then
  echo "${LOG_PREFIX} 현재 Standby라 백업을 건너뜁니다 (pg_is_in_recovery=t)"
  exit 0
fi
if [ "${in_recovery}" != "f" ]; then
  echo "${LOG_PREFIX} PostgreSQL 역할을 확인할 수 없어 백업을 건너뜁니다 (pg_is_in_recovery='${in_recovery}')" >&2
  exit 0
fi
# 여기부터는 이 노드가 Primary — 아래 기존 백업 로직 그대로
```
- 스크립트는 systemd `User=postgres`로 실행되므로 `sudo -u postgres`는 불필요하다(기존 `pg_dump -U postgres`와 동일 방식). bare `psql -U postgres`로 통일했다.
- 세 번째 분기(결과가 `t`/`f` 둘 다 아님 = postgres 미기동 등)도 `exit 0`으로 처리해 타이머가 실패로 남지 않게 했다.

🔴 **service 파일에서 `Requires=postgresql.service` / `After=postgresql.service` 제거**:
- §16-10 Phase 3에서 `postgresql.service`를 **mask**했으므로(PAF가 `pg_ctl`로 직접 관리), `Requires=`를 그대로 두면 `systemctl start pg-logical-backup.service`가 `Unit postgresql.service is masked`로 실패한다.
- 새 스크립트의 역할 확인 로직이 "postgres가 떠 있고 Primary인가"를 스스로 판단하므로 systemd 레벨 의존성은 불필요하다.

**배포**:
- db02: 기존 3파일을 `*.bak-20260909`로 백업 후 덮어썼다.
- db01: §15-8에서 옛 cron 방식을 폐기해 둔 상태라 스크립트/유닛을 새로 생성했다.
- 두 노드 스크립트 sha256은 동일하다(`7de85d03…`). 권한은 `postgres:postgres 700` + `bin_t`, 유닛 `root:root 644` + `systemd_unit_file_t`이다.
- `/pgbackup`: db01도 이미 `postgres:postgres` + `postgresql_db_t`였다(db02와 동일). §15의 `root:root` 문제는 재현되지 않았다.
- `systemctl daemon-reload` → 두 노드에서 `systemctl enable --now pg-logical-backup.timer`를 실행했다.

**검증**:
- db01, Primary (`pg_is_in_recovery=f`): `systemctl start` 결과 `success`, exit 0. 로그 `시작 → 완료 → 보관 정리`. 파일 `appdb_<ts>.dump` + `globals_<ts>.sql`이 생성됐다.
- db02, Standby (`=t`): 같은 명령의 결과 `success`, exit 0. 로그 `현재 Standby라 백업을 건너뜁니다`. 새 파일은 없었다(개수 10 → 10 그대로).

- `systemctl list-timers`: 두 노드 다 `NEXT = 매일 02:00:00 UTC`, `enabled`.
- 롤백: db02는 `*.bak-20260909` 3파일로 복원할 수 있다.


---

