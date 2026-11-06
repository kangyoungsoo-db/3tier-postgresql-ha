> 이 문서는 `3tier-rocky10-guide-v16.md` 의 2809~3634줄을 그대로 옮긴 것이다. 비밀번호와 로컬 경로만 자리표시자로 바꿨다.

## 11. db02 이중화 — PostgreSQL 스트리밍 복제(Primary-Standby) 구성

web/was 계층은 §9~§10에서 Pacemaker로 이중화를 마쳤습니다. 이 챕터는 DB 계층(db01)에 **db02를 Standby로 붙이는 작업**입니다. DBA 지향 포트폴리오 보완 목적으로, 지금 단계에서는 자동 페일오버(Pacemaker)까지는 하지 않고 **스트리밍 복제 구성 + 수동 승격(promote) 연습**까지를 목표로 합니다.

> **핵심 개념 요약**
> - **db01(Primary)**: 모든 쓰기가 여기로만 들어오고, 변경사항이 **WAL(Write-Ahead Log)**로 순서대로 기록됩니다.
> - **db02(Standby)**: db01의 WAL을 실시간으로 받아 자기 데이터에 재생(replay)합니다. 기본적으로 **읽기 전용**이며, 승격(promote) 전까지는 쓰기를 받을 수 없습니다.
> - **초기 동기화**는 `pg_basebackup`으로 합니다 — db01의 현재 데이터 전체를 db02로 통째로 복사한 뒤, 그 이후부터 WAL로 계속 따라잡습니다. **`initdb`로 만들면 안 됩니다** — db01과 무관한 별개의 클러스터가 생겨 복제 연결이 거부됩니다.
> - **복제 슬롯(Replication Slot)**: db02가 잠깐 끊겨도 db01이 필요한 WAL을 함부로 지우지 않고 보관하게 하는 안전장치입니다.

### 11-1. Vagrantfile에 db02 추가

`NODES` 해시에 db01과 동일한 스펙으로 추가합니다. ⚠️ **기존 마지막 항목인 db01 블록 끝의 `}`를 `},`로 바꿔 쉼표를 붙인 뒤** 그 아래에 db02를 넣으세요. Ruby 해시는 항목 사이에 쉼표가 필요해서, 빠지면 `vagrant` 명령이 문법 오류로 멈춥니다(v16 r23 — 실제로 겪음: 쉼표 없이 저장하고 `vagrant` 명령을 실행하자 `Vagrantfile:39: syntax error, unexpected string literal, expecting '}'`로 멈췄고, `}` 뒤에 쉼표를 붙이자 해결됐습니다. 오류의 줄 번호는 새로 넣은 `"db02" => {` 줄을 가리킵니다). 새로 마지막이 되는 db02의 `}`는 쉼표 없이 둡니다.
```ruby
"db02" => {
  ip_mgmt: "192.168.10.114",
  mem: 2560, cpu: 2,
  extra_disks: [
    { name: "pgdata",   size: 20 },
    { name: "pgwal",    size: 5 },
    { name: "pgbackup", size: 5 }
  ]
}
```

| 서버 | 관리망 IP | bond0(서비스망) IP |
|---|---|---|
| db02 | 192.168.10.114 | 10.10.10.24/24 |

🖥️ 호스트 PC에서:
```bash
vagrant status    # Vagrantfile을 저장한 직후 문법 확인 — 오류 없이 db02가 `not created`로 보이면 정상(예상 출력, 미실행)
vagrant up db02
```

`vagrant up db02`가 끝나면 db02에도 §3-1~§3-4(호스트명 · `/etc/hosts` · 관리망 · 기본 도구)를 web02/was02(§9-1)처럼 적용합니다. 재현 기록(2026-10-03, v16 r23): §11-5 시점의 db02에서 `grep -E 'db01|web01' /etc/hosts`가 아무것도 출력하지 않았습니다(= `/etc/hosts`에 다른 노드가 아직 없음). IP로 하는 ping·복제는 hosts 없이도 동작해서 §11은 통과했지만, §16처럼 이름으로 노드를 부르는 단계(`host=witness01` 등) 전에는 채워 두는 편이 안전합니다. ⚠️ 이 PC의 db02는 인터넷이 되지 않았습니다(§11-5 1)). §3-4의 `dnf install`은 외부 저장소가 필요하므로 db02에서는 실패하거나 오래 멈출 수 있습니다 — 그럴 때는 §11-3의 로컬 저장소 등록 뒤에 같은 도구를 설치하세요(`chrony` 등 나머지 도구가 로컬 저장소에 다 들어 있는지는 **미확인**).

### 11-2. 서비스망 bond0 구성 — db02

**IP를 1개만 주는 이유**: db01은 실제로 `10.10.10.13`(기본) + `10.10.10.23`(서비스/향후 VIP 후보, §0에서 처음부터 예약해둔 값)을 **둘 다** bond0에 갖고 있습니다. db02에 `10.10.10.23`을 그대로 쓰면 db01과 IP 충돌이 나므로, db02는 **새 번호 `10.10.10.24` 하나만** 부여합니다.

🖥️ **db02**에서 (db01의 실제 bond0 설정 — mode/miimon/슬레이브 NIC 이름 — 을 먼저 확인한 뒤 그대로 따라갑니다):
```bash
sudo nmcli connection add type bond ifname bond0 con-name bond0 \
  bond.options "mode=active-backup,miimon=100"

sudo nmcli connection modify bond0 \
  ipv4.addresses "10.10.10.24/24" ipv4.gateway "10.10.10.1" \
  ipv4.method manual ipv6.method disabled

sudo nmcli connection add type ethernet ifname enp0s9  master bond0 con-name bond0-port1
sudo nmcli connection add type ethernet ifname enp0s10 master bond0 con-name bond0-port2

sudo nmcli connection up bond0-port1
sudo nmcli connection up bond0-port2
sudo nmcli connection up bond0
```

**노드 간 통신 확인** (db01의 기존 IP가 안 건드려졌는지까지 같이 확인):

🖥️ **db02**에서:
```bash
ping -c 3 10.10.10.13    # db01 기본 IP
ping -c 3 10.10.10.23    # db01 서비스 IP(secondary) — 이것도 살아있어야 정상
```
🖥️ **db01**에서:
```bash
ping -c 3 10.10.10.24    # db02
```
전부 `0% packet loss`가 나와야 합니다.

### 11-3. db02 로컬 저장소 등록 + PostgreSQL 패키지 설치

**미리 확인한 사실** (v16 r22 정정): 예전 가이드는 '로컬 저장소에 PostgreSQL 패키지가 없다'고 적었지만, §4-6에서 `postgresql-server postgresql-contrib`를 함께 받으므로 지금은 들어 있습니다. db01이 실제로 쓰는 PostgreSQL은 PGDG의 `postgresql16-server`가 아니라 **Rocky AppStream의 무버전 패키지 `postgresql-server`**입니다. 복제는 Primary/Standby가 동일 빌드여야 안전하므로, db02도 **같은 이름으로, 같은 로컬 저장소에서** 설치합니다. 재현 기록: db02는 `postgresql-server-16.15-1.el10_2.x86_64`(db01 재현 기록의 16.15와 일치; 같은 화면에서 비교한 것은 아님). 빌드 번호는 시점에 따라 바뀔 수 있으니 가이드의 숫자가 아니라 **db01의 `rpm -q postgresql-server` 결과와 같은지**로 판단하세요.

먼저 web01의 저장소가 살아 있는지 확인합니다(§10-5 ⚠️ — `web_httpd`가 web02에 있으면 저장소가 꺼져 있습니다):

🖥️ **db02**에서:
```bash
curl -sI http://192.168.10.111/repo/rocky10/local/repodata/repomd.xml | head -1    # HTTP/1.1 200 OK 여야 함
```
`200 OK`가 아니면 §10-5의 복구부터 하세요. 그다음:

🖥️ **db02**에서:
```bash
sudo tee /etc/yum.repos.d/local-web01.repo <<'EOF'
[local-web01]
name=Internal Repo via web01
baseurl=http://192.168.10.111/repo/rocky10/local
enabled=1
gpgcheck=0
EOF

# 외부 저장소는 끈다 (was01/db01과 같게; v16 r22 — 켜 두면 db01과 다른 빌드가 설치될 수 있다)
sudo dnf config-manager --set-disabled baseos appstream extras
sudo dnf clean metadata
sudo dnf repolist          # local-web01만 보여야 함

sudo dnf install -y postgresql-server postgresql-contrib
```
재현 기록: `dnf repolist`에 `local-web01`(`Internal Repo via web01`) 한 줄만 보였고, 설치는 `Complete!`였습니다(perl 계열 등 의존성 포함).

**확인 (initdb·서비스 시작이 안 됐는지까지 반드시 확인)**:
```bash
rpm -qa | grep -i postgres          # db01의 같은 명령 결과와 동일 빌드인지 확인 (재현 기록: 16.15-1.el10_2)
systemctl is-enabled postgresql     # disabled
systemctl is-active postgresql      # inactive
sudo ls -la /var/lib/pgsql/data     # 비어있어야 정상 (initdb 안 함; 재현 기록: `total 0`)
```

### 11-4. 방화벽 — db01 ↔ db02 5432 포트 상호 허용

🖥️ **db01**에서:
```bash
sudo firewall-cmd --permanent --zone=public --add-rich-rule=\
'rule family="ipv4" source address="10.10.10.24/32" port protocol="tcp" port="5432" accept'
sudo firewall-cmd --reload
```
🖥️ **db02**에서:
```bash
sudo firewall-cmd --permanent --zone=public --add-rich-rule=\
'rule family="ipv4" source address="10.10.10.13/32" port protocol="tcp" port="5432" accept'
sudo firewall-cmd --reload
```

### 11-5. LVM 구성 — db01과 동일한 구조로 db02에 디스크 준비

**db01의 실제 구성** (먼저 조사한 결과, db02도 이대로 맞춥니다):

| 디스크 | PV | VG | LV | FS | 마운트 |
|---|---|---|---|---|---|
| 20G 디스크 | `$PGDATA_DISK` | vg_pgdata | lv_pgdata (100%FREE) | xfs | /pgdata |
| 5G 디스크 ① | `$PGWAL_DISK` | vg_pgwal | lv_pgwal (100%FREE) | xfs | /pgwal |
| 5G 디스크 ② | `$PGBACKUP_DISK` | vg_pgbackup | lv_pgbackup (100%FREE) | xfs | /pgbackup |

> ⚠️ **v16**: 디스크 문자(`sdb/sdc/sdd`)는 VM마다 다릅니다. 아래 2)를 실행하기 전에 §6-1과 똑같이 '빈 디스크 스캔'으로 크기를 확인하고 `PGDATA_DISK`/`PGWAL_DISK`/`PGBACKUP_DISK`를 정하세요(OS 디스크를 PV로 만드는 사고 방지).

- fstab은 UUID가 아니라 **device-path 방식**(`/dev/vg_xxx/lv_xxx`)을 씁니다.
- systemd override(`/etc/systemd/system/postgresql.service.d/override.conf`)에 `Environment=PGDATA=/pgdata/data` 지정.
- SELinux: `/pgdata`, `/pgwal`, `/pgbackup` 세 경로에 `semanage fcontext` 로컬 규칙으로 `postgresql_db_t` 지정.
- 소유권: `/pgdata`는 postgres:postgres 755, `/pgdata/data`는 postgres:postgres **700**. `/pgwal`·`/pgbackup`은 아래 3)만 따르면 root:root 755로 남습니다 — 가이드 §6-4대로 만든 db01은 두 곳이 postgres:postgres라서 서로 다른 상태입니다(v16 r23). 이 차이가 §12-6(승격 후 WAL 아카이브 실패)·§15-2의 원인이므로, 맞추려면 3) 아래의 선택 항목을 실행하세요.

**1) 도구 설치**

🖥️ **db02**에서:
```bash
sudo dnf install -y lvm2 policycoreutils-python-utils
```

> ⚠️ **(v16 r23, 실제로 겪음) `No match for argument: policycoreutils-python-utils` → `Error: Unable to find a match`가 나오면** — web01 로컬 저장소에 그 패키지가 없는 것입니다. dnf는 하나라도 못 찾으면 전체를 중단해서 **같이 적은 `lvm2`도 설치되지 않습니다.** db02는 이 PC에서 인터넷이 되지 않아(아래) 로컬 저장소가 유일한 저장소였습니다. §4-6 목록에는 이제 이 패키지가 들어 있지만, 이미 저장소를 만들었다면 채워 넣으세요.
>
> 🖥️ **web01**에서:
> ```bash
> dnf download --resolve --alldeps --destdir=/repo/rocky10/local policycoreutils-python-utils
> createrepo_c /repo/rocky10/local
> restorecon -Rv /repo/rocky10/local/ | tail -3     # 출력이 없으면 라벨이 이미 맞는 것
> ls /repo/rocky10/local/*.rpm | wc -l               # 재현 기록: 475 → 490 (15개 추가)
> ```
> 🖥️ **db02**에서: `sudo dnf clean metadata` 후 위 `dnf install`을 다시 실행합니다.
>
> **실패한 우회 (같은 방법을 시도하지 마세요)**: 외부 저장소를 잠깐 켜는 `dnf install --enablerepo=baseos --enablerepo=appstream …`은 이 PC의 db02에서 `Curl error (28) … Resolving timed out after 30004 ms`로 멈췄고 `curl`도 응답이 없었습니다. `ip route`에는 default 경로가 3개(관리망 `192.168.10.1` metric 102, NAT `10.0.2.2` metric 103, bond0 `10.10.10.1` metric 300)였습니다. 가장 낮은 metric의 관리망 게이트웨이가 인터넷으로 나가는 길이 아닐 수 있다는 것은 **추정이며 확인하지 않았습니다**(원인 미확인). 폐쇄망 구성에서는 외부 접속에 기대지 않는 게 원래 방향이라 저장소를 채우는 쪽으로 해결했습니다.

**2) LVM + 파일시스템 + 마운트**

🖥️ **db02**에서:
```bash
sudo pvcreate $PGDATA_DISK $PGWAL_DISK $PGBACKUP_DISK

sudo vgcreate vg_pgdata   $PGDATA_DISK
sudo vgcreate vg_pgwal    $PGWAL_DISK
sudo vgcreate vg_pgbackup $PGBACKUP_DISK

sudo lvcreate -l 100%FREE -n lv_pgdata   vg_pgdata
sudo lvcreate -l 100%FREE -n lv_pgwal    vg_pgwal
sudo lvcreate -l 100%FREE -n lv_pgbackup vg_pgbackup

sudo mkfs.xfs /dev/vg_pgdata/lv_pgdata
sudo mkfs.xfs /dev/vg_pgwal/lv_pgwal
sudo mkfs.xfs /dev/vg_pgbackup/lv_pgbackup

sudo mkdir -p /pgdata /pgwal /pgbackup
sudo mount /dev/vg_pgdata/lv_pgdata     /pgdata
sudo mount /dev/vg_pgwal/lv_pgwal       /pgwal
sudo mount /dev/vg_pgbackup/lv_pgbackup /pgbackup

sudo tee -a /etc/fstab >/dev/null <<'EOF'
/dev/vg_pgdata/lv_pgdata      /pgdata     xfs   defaults   0 0
/dev/vg_pgwal/lv_pgwal        /pgwal      xfs   defaults   0 0
/dev/vg_pgbackup/lv_pgbackup  /pgbackup   xfs   defaults   0 0
EOF

# fstab이 재부팅 시에도 정상 마운트되는지 즉시 검증
sudo umount /pgdata /pgwal /pgbackup
sudo mount -a
df -h | grep -E "pgdata|pgwal|pgbackup"
```
재현 기록(db02, v16 r23): `df -h`가 `/pgdata` 20G(사용 424M), `/pgwal`·`/pgbackup` 각 5.0G(사용 130M)를 보였습니다. `mount -a` 뒤에 `your fstab has been modified, but systemd still uses the old version; use 'systemctl daemon-reload' to reload.`라는 안내가 나왔지만 세 곳 모두 정상 마운트됐고 영향은 없었습니다(마음에 걸리면 `sudo systemctl daemon-reload`를 한 번 실행).

**3) `/pgdata/data` 준비 — initdb는 하지 않습니다**

🖥️ **db02**에서:
```bash
sudo mkdir -p /pgdata/data
sudo chown postgres:postgres /pgdata /pgdata/data
sudo chmod 700 /pgdata/data

sudo ls -A /pgdata/data     # 비어있어야 정상 (count 0)
```

> **(선택, 권장) `/pgwal`·`/pgbackup` 소유권을 db01과 맞추기 (v16 r23)** — 위 3)은 두 곳을 `root:root`로 둡니다. 가이드 §6-4대로 만든 db01은 `postgres:postgres`라서 서로 다릅니다. db02가 Primary가 되는 순간(§12-5) `archive_command`(`cp … /pgwal/…`)가 `Permission denied`로 실패하는 것이 §12-6의 버그이고, `/pgbackup`은 §15-2에서 같은 이유로 막힙니다. 미리 맞추려면:
> ```bash
> sudo chown postgres:postgres /pgwal /pgbackup
> sudo ls -ldZ /pgwal /pgbackup    # postgres postgres … (라벨은 아래 4)에서 postgresql_db_t가 됨)
> ```
> 하지 않고 §12~§15에서 그 오류를 직접 겪고 고치는 길도 있습니다(가이드가 그 경로를 설명합니다). 어느 쪽이든 db02가 Primary로 쓰기 전에는 맞아 있어야 합니다. 이 항목을 실행했는지는 이 가이드가 정하지 않습니다.

**4) SELinux 컨텍스트**

🖥️ **db02**에서:
```bash
sudo semanage fcontext -a -t postgresql_db_t "/pgdata(/.*)?"
sudo semanage fcontext -a -t postgresql_db_t "/pgwal(/.*)?"
sudo semanage fcontext -a -t postgresql_db_t "/pgbackup(/.*)?"
sudo restorecon -Rv /pgdata /pgwal /pgbackup
```
재현 기록(db02): `Relabeled` 4줄이 나왔습니다(`/pgdata`, `/pgdata/data`, `/pgwal`, `/pgbackup` — 이전 라벨 `unlabeled_t` → `postgresql_db_t`).

**5) systemd override — db01과 바이트 단위로 동일하게**

🖥️ **db01**에서 원본 확인:
```bash
sudo cat -A /etc/systemd/system/postgresql.service.d/override.conf
sudo sha256sum /etc/systemd/system/postgresql.service.d/override.conf
```
🖥️ **db02**에서 동일하게 생성:
```bash
sudo mkdir -p /etc/systemd/system/postgresql.service.d
sudo tee /etc/systemd/system/postgresql.service.d/override.conf <<'EOF'
[Service]
Environment=PGDATA=/pgdata/data
EOF
sudo systemctl daemon-reload

sudo sha256sum /etc/systemd/system/postgresql.service.d/override.conf   # db01과 해시 비교
```
재현 기록: 두 노드 모두 `d596d04e6d7eb61b9b06e726817860a37e7263b8e31bd9aaf6f3acbbb76c06f2`로 같았습니다.

**6) 최종 대조 (db01 ↔ db02)**

| 확인 항목 | 확인 방법 |
|---|---|

1. lsblk (VG/LV 이름·크기·FS·마운트) | `lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS` |

2. df -h | `/pgdata`·`/pgwal`·`/pgbackup` 마운트 확인(db02는 아직 빈 xfs라 Used 용량이 db01보다 훨씬 작은 게 정상) |

3. systemd override 내용 | `systemctl cat postgresql \| sed -n '/postgresql.service.d/,$p'` |

4. PGDATA 환경변수 | `systemctl show postgresql -p Environment` |

5. fstab pg 관련 3줄 | `grep -E "pgdata\|pgwal\|pgbackup" /etc/fstab` |

### 11-6. db01 — 복제 계정 및 pg_hba.conf 설정

**1) 복제 관련 설정값 확인** (기본값이면 수정 불필요):
```bash
sudo -u postgres psql -c "SHOW wal_level"              # replica 이상
sudo -u postgres psql -c "SHOW max_wal_senders"         # 1 이상 (기본 10)
sudo -u postgres psql -c "SHOW max_replication_slots"   # 1 이상 (기본 10)
```

**2) 복제 전용 계정 생성** — 기존 앱 계정(`app_user`)과는 별개로, `REPLICATION` 권한만 가진 계정을 새로 만듭니다:

🖥️ **db01**에서:
```bash
sudo -u postgres psql -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '<REPLICATION_PASSWORD>';"
```

> ⚠️ **`<REPLICATION_PASSWORD>`는 자리표시자입니다 — 꺾쇠(`<>`)까지 통째로 입력하면 안 됩니다 (v16 r23, 실제로 겪음).** 그대로 실행하면 비밀번호가 문자 그대로 `<REPLICATION_PASSWORD>`인 계정이 만들어집니다. 실습에서는 `<REPLICATION_PASSWORD>`처럼 간단한 영문 소문자로 정해 §11-7에도 **똑같이** 쓰세요(예: `PASSWORD '<REPLICATION_PASSWORD>'`). 이미 자리표시자 그대로 실행했다면 같은 `CREATE ROLE`을 다시 실행하지 마세요 — `ERROR: role "replicator" already exists`가 납니다(첫 실행으로 계정은 이미 생겼습니다). 비밀번호만 바꾸면 됩니다:
> ```bash
> sudo -u postgres psql -c "ALTER ROLE replicator WITH PASSWORD '<REPLICATION_PASSWORD>';"    # 출력: ALTER ROLE
> ```

**3) `pg_hba.conf`에 replication 전용 규칙 추가** — 일반 접속(`host all all ...`)과 별개로, `replication`이라는 가상 데이터베이스 이름으로 규칙이 따로 필요합니다:

🖥️ **db01**에서:
```bash
echo "host    replication     replicator      10.10.10.24/32       scram-sha-256" | \
  sudo tee -a /pgdata/data/pg_hba.conf

sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

**4) 반영 확인**:
```bash
sudo -u postgres psql -xc "SELECT line_number, type, database, user_name, address, auth_method, error FROM pg_hba_file_rules WHERE 'replication' = ANY(database) OR user_name::text LIKE '%replicator%';"
```
`error` 컬럼이 비어있고 `auth_method`가 `scram-sha-256`이면 정상입니다.

### 11-7. db02 — pg_basebackup으로 초기 동기화

```bash
sudo -u postgres env PGPASSWORD='<REPLICATION_PASSWORD>' pg_basebackup \
  -h 10.10.10.13 -U replicator \
  -D /pgdata/data \
  -P -v -X stream -C -S db02_slot -R
```

> ⚠️ **`PGPASSWORD=값`을 `sudo`보다 앞에 쓰면 안 됩니다.** `PGPASSWORD='...' sudo -u postgres pg_basebackup ...`처럼 쓰면 `sudo`가 환경변수를 걸러내서 비밀번호가 전달되지 않습니다. 위처럼 `sudo -u postgres env PGPASSWORD='...' pg_basebackup ...` — `env`로 감싸서 `sudo` **뒤**에 둬야 합니다.

**옵션 설명**:
| 옵션 | 의미 |
|---|---|
| `-h 10.10.10.13 -U replicator` | db01에 replicator 계정으로 접속 |
| `-D /pgdata/data` | 준비해둔 빈 디렉터리에 db01 데이터를 통째로 복사 |
| `-X stream` | 백업 진행 중 발생하는 WAL도 실시간으로 같이 받음 |
| `-C -S db02_slot` | `db02_slot`이라는 이름으로 복제 슬롯을 db01에 자동 생성 |
| `-R` | 완료 후 `standby.signal`과 `primary_conninfo`(db01 재접속 정보)를 자동 생성 |

정상 완료 시 `pg_basebackup: base backup completed` 메시지가 마지막에 나옵니다. 재현 기록(v16 r23): `30876/30876 kB (100%)`까지 진행되고 `pg_basebackup: created replication slot "db02_slot"` 뒤 `base backup completed`로 끝났습니다. `-R`이 만든 `postgresql.auto.conf`의 `primary_conninfo`에는 §11-6의 비밀번호가 **평문으로** 들어갑니다(정상 동작 — 이 파일은 postgres 계정만 읽을 수 있는 700 디렉터리 안에 있습니다. 실습 밖에서는 `.pgpass`나 인증서 방식을 고려).

### 11-8. 결과 확인

🖥️ **db02**에서:
```bash
sudo ls -la /pgdata/data/standby.signal      # 존재해야 함 (0바이트 파일)
sudo grep -E "primary_conninfo|primary_slot_name" /pgdata/data/postgresql.auto.conf
```
`primary_conninfo`에 `host=10.10.10.13`, `user=replicator`가, `primary_slot_name`에 `db02_slot`이 들어있어야 합니다.

🖥️ **db01**에서:
```bash
sudo -u postgres psql -xc "SELECT slot_name, slot_type, active, wal_status FROM pg_replication_slots;"
```
`db02_slot | physical | f | reserved`로 나오면 정상입니다 — `active`가 `f`(false)인 이유는 db02의 postgresql 서비스가 **아직 시작 전**이라 실제 연결이 없기 때문입니다.

재현 기록(v16 r23): `standby.signal`이 `-rw------- postgres postgres 0`(0바이트)으로 있었습니다.

### 11-9. db02에서 postgresql 서비스 시작

🖥️ **db02**에서:
```bash
sudo systemctl start postgresql
```
> 아직 `enable`은 하지 않습니다 — 정상 동작을 완전히 확인한 뒤 §11-12에서 켭니다.

**확인**:
```bash
systemctl is-active postgresql     # active
systemctl is-enabled postgresql    # disabled (의도한 상태)
```

### 11-10. 실제 복제 동작 확인 (end-to-end)

🖥️ **db01**에서 streaming 상태 확인:
```bash
sudo -u postgres psql -xc "SELECT pid, usename, application_name, client_addr, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;"
sudo -u postgres psql -xc "SELECT slot_name, active, active_pid, wal_status FROM pg_replication_slots;"
```
`state = streaming`, `client_addr = 10.10.10.24`, 슬롯 `active = t`가 나와야 합니다.

🖥️ **db02**에서:
```bash
sudo -u postgres psql -Atc "SELECT pg_is_in_recovery();"   # t 이어야 함 (읽기 전용)
sudo -u postgres psql -xc "SELECT status, sender_host, slot_name, latest_end_lsn FROM pg_stat_wal_receiver;"
```

**가장 확실한 증거 — db01에 써서 db02에서 확인**:

`pg_stat_replication`이 `streaming`으로 보여도, 실제로 데이터가 넘어가는지 직접 써보는 게 제일 확실합니다.

🖥️ **db01**에서:
```bash
sudo -u postgres psql -c "CREATE TABLE IF NOT EXISTS repl_check(t timestamptz); INSERT INTO repl_check VALUES (now());"
```
2~3초 대기 후 🖥️ **db02**에서:
```bash
sudo -u postgres psql -Atc "SELECT count(*), max(t) FROM repl_check;"
```
`count=1`과 방금 넣은 시각이 그대로 나오면 복제가 실제로 동작하는 겁니다.

재현 기록(v16 r23): db01 `pg_stat_replication`이 `application_name = walreceiver`, `client_addr = 10.10.10.24`, `state = streaming`, `sync_state = async`, `sent_lsn = replay_lsn = 0/6000060`이었고, db02 `pg_stat_wal_receiver`는 `status = streaming`, `sender_host = 10.10.10.13`, `slot_name = db02_slot`, `latest_end_lsn = 0/6000060`이었습니다. `repl_check` 조회는 `1|2026-10-03 16:30:35.713711+00`이었습니다.

확인 후 정리 — 🖥️ **db01**에서:
```bash
sudo -u postgres psql -c "DROP TABLE IF EXISTS repl_check;"
```
🖥️ **db02**에서 (DDL도 복제되는지 같이 확인):
```bash
sudo -u postgres psql -Atc "SELECT to_regclass('repl_check');"    # NULL이 나와야 함
```

### 11-11. `listen_addresses` 수정 — pg_basebackup이 db01 설정을 그대로 복사해오는 문제

**실제로 겪은 문제**: db02의 PostgreSQL 로그(`/pgdata/data/log/*.log`)에 아래 경고가 남아있었습니다:
```
LOG:  could not bind IPv4 address "10.10.10.13": Cannot assign requested address
WARNING:  could not create listen socket for "10.10.10.13"
```
**원인**: `pg_basebackup`은 db01의 `postgresql.conf`를 파일째로 그대로 복사해옵니다. 그 안에 `listen_addresses = 'localhost,10.10.10.13'`(db01 자신의 IP)이 박혀있는 채로 db02에 왔기 때문에, db02가 자기 것이 아닌 IP로 리슨을 시도하다 실패한 겁니다. **복제 자체는 db02가 db01에게 먼저 접속을 거는 방식이라 지장이 없었지만**, db02가 나중에 읽기 트래픽을 직접 받거나 승격될 상황을 대비해 지금 고쳐둡니다.

🖥️ **db02**에서:
```bash
sudo cp -p /pgdata/data/postgresql.conf /pgdata/data/postgresql.conf.bak.$(date +%Y%m%d%H%M%S)
sudo sed -i "s/^listen_addresses = 'localhost,10.10.10.13'/listen_addresses = 'localhost,10.10.10.24'/" /pgdata/data/postgresql.conf
sudo grep -nE "^listen_addresses" /pgdata/data/postgresql.conf
```
> `listen_addresses`는 재시작이 필요한 설정입니다. db02는 지금 standby라 재시작해도 데이터 유실 위험이 없습니다(다시 시작하면 자동으로 db01에 재접속).
```bash
sudo systemctl restart postgresql
sleep 4
systemctl is-active postgresql
sudo -u postgres psql -Atc "SHOW listen_addresses;"
sudo ss -tlnp | grep 5432    # 10.10.10.24:5432 가 새로 떠 있어야 함
```

**재시작 후 복제가 다시 붙었는지 db01에서 재확인**:
```bash
sudo -u postgres psql -xc "SELECT client_addr, state, sync_state FROM pg_stat_replication;"
```
`state = streaming`으로 돌아오면 완료입니다. 재현 기록(v16 r23): 수정 뒤 `SHOW listen_addresses`가 `localhost,10.10.10.24`였고 `ss -tlnp`에 `10.10.10.24:5432`가 LISTEN으로 보였습니다. (db01 자신의 `listen_addresses`는 처음부터 `localhost,10.10.10.13`으로 올바르게 자기 IP를 가리키고 있어 손댈 필요 없습니다.)

### 11-12. 재부팅 시 자동 시작 활성화

모든 검증이 끝난 지금에서야 `enable`합니다 — 확인 전에 미리 켜두면, 문제가 있는 상태로 재부팅됐을 때 그 문제가 자동으로 반복될 수 있어 의도적으로 마지막에 합니다.

🖥️ **db01, db02** 둘 다에서:
```bash
sudo systemctl enable postgresql
systemctl is-enabled postgresql    # enabled
```
> 참고: db01은 이미 `enabled` 상태로 나올 수 있습니다 — `vagrant reload`(재부팅) 때 자동으로 다시 켜졌던 이력이 있다면 그렇습니다. 문제없습니다.

### 11-13. 최종 확인 체크리스트

| 확인 항목 | 명령어 | 정상 기준 |
|---|---|---|
| db01 복제 상태 | `pg_stat_replication`에서 `state` | `streaming` |
| db01 슬롯 상태 | `pg_replication_slots`에서 `active` | `t` |
| db02 읽기 전용 | `SELECT pg_is_in_recovery();` | `t` |
| db02 리슨 주소 | `SHOW listen_addresses;` | `localhost,10.10.10.24` |
| db02 실제 소켓 | `ss -tlnp \\| grep 5432` | `10.10.10.24:5432` 포함 |
| 재부팅 자동시작 | `systemctl is-enabled postgresql` (양쪽) | `enabled` |

재현 기록(2026-10-03, v16 r23): 위 여섯 항목이 모두 기준대로였습니다(db01·db02 모두 `enabled`). 다만 §11-11에서 db02를 재시작한 뒤의 db01 `streaming` 재확인과 그 재시작의 선후는 로그만으로는 증명할 수 없으므로, §12로 넘어가기 전에 db01에서 `SELECT client_addr, state, sync_state FROM pg_stat_replication;`를 한 번 더 확인하는 편이 안전합니다.

### 11-14. 다음 단계

1. **수동 페일오버 연습**: db01을 내려보고 db02에서 `SELECT pg_promote();`로 승격시켜 실제로 쓰기 가능한 상태로 전환하는 것까지 실습
2. **(선택)** Pacemaker + `resource-agents-paf`로 DB 계층까지 자동 페일오버 구성
3. **(선택)** `pg_dump` 백업의 실제 복원 리허설, PITR 연습

이 항목들은 실제 로그를 보면서 하나씩 진행하는 게 지금까지처럼 안전합니다 — 준비되시면 이어서 진행하겠습니다.

**§12~§16의 성격과 순서 의존 (v16 r23)** — 이 장들이 전부 '연습'은 아닙니다. 연습·검증과 구축이 섞여 있고, 앞 장이 만든 **상태**를 뒤 장이 전제합니다. 아래는 가이드를 읽고 정리한 것이며, 순서를 바꿔 직접 해 본 것은 아닙니다(건너뛰었을 때의 결과는 **미확인**).

| 장 | 성격 | 이 장이 남기는 상태 (뒤 장이 쓰는 것) | 건너뛰면 |
|---|---|---|---|
| §12 | 연습 (수동 페일오버) | db02가 Primary(타임라인 2). §12-6에서 `/pgwal` 소유권 점검 | db02가 Standby로 남아 §14·§15·§16의 'db02=Primary' 전제와 어긋남 — 명령의 db01/db02를 서로 바꿔 읽어야 함 |
| §13 | §12의 뒷정리지만 설정이 남음 | db01이 db02의 Standby, 양쪽 `wal_log_hints=on` | §16이 전제하는 복제 방향(db02→db01)과 슬롯 상태가 안 만들어짐 |
| §14 | 검증 (PITR 복구 — 페일오버 아님) | 뒤 장이 쓰는 상태 없음 (별도 5433 인스턴스, 끝에 정리) | §15·§16에 영향 없음. 'WAL 아카이브로 실제 복구가 된다'는 증명만 빠짐 |
| §15 | 구축 (pg_dump systemd timer) | `/pgbackup` 쓰기 권한, 백업 스크립트·유닛 | §16-14가 이 스크립트를 역할 인식형으로 고쳐 재배포하므로 같이 가는 것을 권장 |
| §16 | 구축 (PAF + qdevice) + 자동 페일오버 테스트(CP7) | witness01, `db-cluster`, `db_vip`(10.10.10.23) | — |

그래서 '연습 없이 구축으로 바로' 가는 길은 **§14를 건너뛰는 것**이 가장 안전하고, §12~§13은 연습인 동시에 §14~§16이 전제하는 역할 배치(db02 Primary, db01 Standby)를 만드는 단계입니다. 그 두 장을 건너뛰면 §14~§16의 명령을 db01/db02를 뒤집어 읽어야 해서 오히려 실수가 늘 수 있습니다.


## 12. 수동 페일오버(Manual Failover) 연습 — db02 승격 + WAL 아카이빙 버그 발견

§11에서 복제 구성을 마친 뒤, DBA 포트폴리오의 핵심인 **"실제 장애 시 승격시켜본 경험"**을 만들기 위해 수동 페일오버를 연습합니다. db01을 실제로 내리고, db02를 `pg_promote()`로 승격시켜 쓰기 가능한 상태로 전환하는 것까지 직접 검증합니다.

> ⚠️ **이 챕터를 실행하면 db01과 db02의 데이터가 갈라집니다(타임라인 분기).** 승격 이후 db01은 예전 상태 그대로 멈춰있고, db02가 새 Primary가 됩니다. 되돌리려면 §12-1에서 뜬 스냅샷을 복원하거나, §13(예정)의 `pg_rewind`로 db01을 새 Standby로 재동기화해야 합니다. **연습이 아니라 실제 운영이라면, 이 절차는 진짜 장애 상황에서만 실행하세요.**

### 12-1. 사전 준비 — VirtualBox 스냅샷 (되돌리기 안전장치)

`pg_promote()`는 간단히 되돌릴 수 없는 명령이라(새 타임라인이 시작됨), 실행 전에 두 VM 모두 스냅샷을 떠둡니다.

🖥️ 호스트 PC에서 (`VBoxManage`가 PATH에 없으면 전체 경로 사용):
```powershell
$vbm = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
& $vbm snapshot "3t-r10-db01" take "before-pg-promote-test"
& $vbm snapshot "3t-r10-db02" take "before-pg-promote-test"
```
확인:
```powershell
& $vbm snapshot "3t-r10-db01" list
& $vbm snapshot "3t-r10-db02" list
```
되돌릴 때 (VM 정지 상태에서):
```powershell
& $vbm snapshot "3t-r10-db01" restore "before-pg-promote-test"
& $vbm snapshot "3t-r10-db02" restore "before-pg-promote-test"
```

### 12-2. 시작 전 복제 상태 최종 확인

🖥️ **db01**에서:
```bash
sudo -u postgres psql -xc "SELECT client_addr, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;"
```
🖥️ **db02**에서:
```bash
sudo -u postgres psql -Atc "SELECT pg_is_in_recovery();"   # t
```
양쪽 LSN이 일치하는 상태에서 시작하는 게 이상적입니다. 재현 기록(2026-10-05, v16 r24): db01 `pg_stat_replication`이 `streaming`, `async`, `sent_lsn = replay_lsn = 0/6017B00`이었습니다.

### 12-3. db01 장애 시뮬레이션 — 서비스 중지

🖥️ **db01**에서:
```bash
sudo systemctl stop postgresql
systemctl is-active postgresql     # inactive
sudo ss -tlnp | grep 5432 || echo "(5432 not listening)"
```
> `enable` 상태는 그대로 둡니다 — 재부팅하면 다시 뜨는 상태입니다. 지금은 프로세스만 멈춘 겁니다.

### 12-4. db02는 자동으로 아무것도 하지 않는다 — 관찰

🖥️ **db02**에서 (아무것도 바꾸지 않고 관찰만):
```bash
sudo -u postgres psql -Atc "SELECT pg_is_in_recovery();"    # 여전히 t
sudo -u postgres psql -xc "SELECT status, sender_host, last_msg_receipt_time FROM pg_stat_wal_receiver;"   # 0 rows (연결 끊김)
sudo bash -c 'ls -t /pgdata/data/log/*.log | head -1 | xargs tail -15'
```
로그에 이런 재시도 메시지가 반복됩니다:
```
FATAL:  could not connect to the primary server: ... Connection refused
LOG:  waiting for WAL to become available at ...
```
재현 기록(2026-10-05, v16 r24): db01을 내린 뒤 db02의 `pg_stat_wal_receiver`는 `(0 rows)`였고, 로그에 `could not connect to the primary server: … Connection refused`와 `waiting for WAL to become available at 0/70000B8`이 5초 간격으로 반복됐습니다. 이 위치가 12-2의 `0/6017B00`보다 앞서 보이는 것은 아카이빙이 켜진 서버가 정상 종료할 때 마지막 WAL 세그먼트를 넘기고 종료 체크포인트를 새 세그먼트에 쓰기 때문으로 보입니다(PostgreSQL 일반 동작에 따른 **추정**, 이 PC에서 확인하지 않음).

**이게 핵심 포인트입니다** — 자동 페일오버가 없는 순수 스트리밍 복제에서는, Primary가 죽어도 Standby가 스스로 승격하지 않고 그냥 무한히 재접속만 시도합니다. 사람이 직접 승격시켜야 합니다(나중에 Pacemaker+PAF를 붙이면 이 지점이 자동화됩니다).

### 12-5. db02를 Primary로 승격

🖥️ **db02**에서:
```bash
sudo -u postgres psql -Atc "SELECT pg_promote();"    # t
```
몇 초 뒤:
```bash
sudo -u postgres psql -Atc "SELECT pg_is_in_recovery();"    # f 로 전환
sudo ls -la /pgdata/data/standby.signal    # No such file (삭제됨 = 승격 완료 신호)
sudo -u postgres psql -Atc "SELECT timeline_id FROM pg_control_checkpoint();"    # 1 → 2
```

**쓰기 가능한지 직접 확인 (가장 확실한 증거)**:
```bash
sudo -u postgres psql -c "CREATE TABLE promote_test(t timestamptz);" -c "INSERT INTO promote_test VALUES (now());" -c "SELECT * FROM promote_test;"
```
Standby였다면 `ERROR: cannot execute CREATE TABLE in a read-only transaction`가 났을 자리에서, 승격 후에는 정상적으로 성공합니다.

재현 기록(2026-10-05, v16 r24): `pg_promote()` → `t`, `pg_is_in_recovery()` → `f`, `standby.signal` 없음, 타임라인 `2`, `promote_test`에 `2026-10-05 08:35:07+00` 한 행이 기록됐습니다.

로그에도 승격 기록이 남습니다:
```
LOG:  received promote request
LOG:  selected new timeline ID: 2
LOG:  archive recovery complete
LOG:  database system is ready to accept connections
```

> 💡 **`pg_promote()`가 하는 일**: WAL 재생을 멈추고 지금까지 받은 데이터를 확정 → `standby.signal` 삭제(더 이상 Standby가 아니라는 표시) → **새 타임라인 시작**. 이제부터 db02가 만드는 WAL은 db01이 예전에 만들던 것과 "다른 역사"가 됩니다. 그래서 db01을 나중에 그냥 재시작하면 안 되고 재동기화(`pg_rewind` 등)가 필요합니다(§13 예정).

### 12-6. 실제로 겪은 문제 — WAL 아카이빙이 Phase 1 때부터 계속 조용히 실패하고 있었음

승격 직후 db02 로그에 이런 에러가 남아있었습니다:
```
cp: cannot create regular file '/pgwal/00000002.history': Permission denied
LOG:  archive command failed with exit code 1
```

**원인 추적**: `pg_promote()`는 새 타임라인을 시작하면서 `.history` 파일을 만들고, `archive_mode=on`(§6-7에서 이미 켜둔 설정)이라 이걸 `archive_command`(`cp %p /pgwal/%f`)로 아카이브하려 시도합니다. 그런데 **`/pgwal` 디렉터리가 `root:root` 소유**라 `postgres` 계정이 그 안에 쓰기를 못 했습니다.

확인해보니 **이 문제는 db02만이 아니라 db01에도 처음부터 있었습니다** — `pg_stat_archiver`를 조회하자 `failed_count`가 이미 수십 건 쌓여있었습니다. §6-7에서 아카이빙을 켜기만 하고 한 번도 실제로 검증한 적이 없어서, Phase 1 때부터 지금까지 계속 조용히 실패만 쌓이고 있었던 것입니다. **"백업/아카이브는 설정만 해두고 실제로 검증 안 하면 조용히 무용지물이 될 수 있다"**는 걸 실전에서 보여준 사례입니다.

> ✅ **이미 §6-4에 소급 반영했습니다** — 지금 이 가이드를 처음부터 새로 따라 하면 이 버그 자체를 안 겪습니다. 아래는 기존 환경(이미 db01/db02가 구축된 상태)에서 고치는 방법입니다.

**해결**:

🖥️ **db01, db02** 둘 다에서:
```bash
sudo chown postgres:postgres /pgwal
sudo ls -ldZ /pgwal    # postgres:postgres, postgresql_db_t 확인 (SELinux 컨텍스트는 이미 맞아 restorecon 불필요했음)
```

**아카이빙이 실제로 정상화됐는지 검증** (강제로 WAL 스위치를 일으켜 확인):

🖥️ **db02**에서:
```bash
sudo -u postgres psql -xc "SELECT archived_count, failed_count, last_failed_time FROM pg_stat_archiver;"   # 수정 전 수치 기록
sudo -u postgres psql -c "SELECT pg_switch_wal();"
sleep 6
sudo -u postgres psql -xc "SELECT archived_count, last_archived_wal, failed_count, last_failed_time FROM pg_stat_archiver;"
```
`archived_count`가 올라가고 `failed_count`/`last_failed_time`이 더 이상 증가하지 않으면(과거 기록은 남아있는 게 정상 — 이 카운터는 리셋되지 않습니다) 해결된 것입니다. `/pgwal` 안에 실제 세그먼트 파일(`postgres:postgres` 소유)이 쌓이는지도 확인하세요.

재현 기록(2026-10-05, v16 r24): 승격 직후 db02 로그에 `cp: cannot create regular file '/pgwal/00000002.history': Permission denied` → `archive command failed with exit code 1`이 그대로 반복됐고, `ls -ldZ /pgwal /pgbackup`은 둘 다 `root root`였습니다(§11-5의 선택 항목을 하지 않은 db02). `sudo chown postgres:postgres /pgwal` 뒤 `pg_stat_archiver`가 `archived_count` 2 → `pg_switch_wal()` 뒤 3, `last_archived_wal = 000000020000000000000007`이었고 `failed_count`(27)와 `last_failed_time`(08:41:28)은 두 번 조회에서 그대로여서 고쳐진 것을 확인했습니다. `/pgbackup`은 이 단계에서 고치지 않았습니다(§15-2).

> ⚠️ **이 버그는 db01에도 그대로 있었던 것이므로, db01을 §13에서 재동기화한 뒤에도 db01의 `/pgwal` 소유권이 postgres:postgres로 맞는지 다시 한번 확인해야 합니다.**

### 12-7. 페일오버 연습 결과 요약

| 검증 항목 | 결과 |
|---|---|
| db01 장애 시 db02 자동 승격 여부 | 안 됨 (예상대로 — 수동 개입 필요, Pacemaker 없이는 정상) |
| `pg_promote()` 실행 | 성공 |
| 승격 후 `pg_is_in_recovery()` | `f`(쓰기 가능) |
| 승격 후 실제 쓰기 테스트 | 성공 |
| 타임라인 전환 | 1 → 2 |
| WAL 아카이빙 | 버그 발견(§12-6) 후 수정, 정상 동작 확인 |

---

## 13. db01 재동기화 — db02 밑에 새 Standby로 복귀

> ✅ **이 챕터는 실제로 처음부터 끝까지(13-1~13-4) 실행하고 실제 로그로 검증을 마쳤습니다.**

### 13-1. 재동기화 방법 선택 — `pg_rewind` 사전 조건부터 확인

db01을 db02 밑에 새 Standby로 붙이는 방법은 두 가지입니다.

| 방법 | 장점 | 조건 |
|---|---|---|
| `pg_rewind` | 바뀐 블록만 복사 → 훨씬 빠름 | **target(db01)이 갈라지기 전부터 `wal_log_hints=on` 또는 데이터 체크섬이 켜져 있어야 함** |
| `pg_basebackup`(§11에서 db02 만들 때와 동일한 방식) | 조건 없음, 이미 검증된 방법 | 전체 복사라 느림(지금 규모에선 체감 차이는 거의 없음) |

**설정 이력상 미리 알 수 있는 사실**: db01은 §6-4에서 `initdb -D /pgdata/data -E UTF8 --locale=C`로 초기화됐고(`--data-checksums` 옵션 없음), §6-7 `postgresql.conf`에도 `wal_log_hints`를 켠 적이 없습니다. 즉 db01이 Primary로 운영되던 내내 이 두 옵션이 꺼져 있었다는 뜻이라, **지금 `wal_log_hints`를 켜도 이미 지나간 구간의 WAL에는 소급 적용되지 않습니다** — `pg_rewind`는 갈라지기 이전 구간의 WAL을 보고 "이 블록이 바뀌었는지"를 판단하는데, 그 구간의 WAL 자체가 이 정보 없이 만들어졌기 때문입니다.

🖥️ **db01**에서 (postgresql은 §12부터 계속 정지 상태 그대로 둔 채):
```bash
sudo -u postgres /usr/bin/pg_controldata /pgdata/data | grep -E "wal_log_hints|checksum"
```

✅ **실측 결과 — 예상과 정확히 일치**:
```
wal_log_hints setting:                off
Data page checksum version:           0
```
→ `pg_rewind`를 시도해도 곧바로 조건 미충족 에러(`target server needs to use either data checksums or "wal_log_hints = on"`)로 거부될 상황이라, 실행해보지 않고 바로 13-2(`pg_basebackup`)로 진행했습니다.

### 13-2. db01을 db02의 새 Standby로 재구성 (`pg_basebackup`) — ✅ 완료

§11에서 db02를 만들 때와 완전히 같은 패턴이되, **방향이 반대**입니다(이번엔 db02가 source, db01이 target).

**1) db01의 옛 데이터 디렉터리는 지우지 말고 옆으로 치워두기** (문제 생기면 다시 들여다볼 수 있게)

🖥️ **db01**에서:
```bash
sudo mv /pgdata/data /pgdata/data.old-primary-$(date +%Y%m%d)
sudo mkdir -p /pgdata/data
sudo chown postgres:postgres /pgdata/data
sudo chmod 700 /pgdata/data
```

**2) db02의 `pg_hba.conf`에 db01용 복제 허용 규칙 추가** — db02의 데이터 디렉터리는 원래 db01을 `pg_basebackup`으로 복제해 만든 것이라, 지금 db02의 `pg_hba.conf`엔 "db02 자신(`10.10.10.24`)이 접속해도 된다"는 규칙만 있고 "db01(`10.10.10.13`)이 접속해도 된다"는 규칙이 없습니다. 방향이 뒤집혔으니 반대쪽 규칙을 새로 추가해야 합니다.

🖥️ **db02**에서:
```bash
sudo -u postgres psql -xc "SELECT line_number, type, database, user_name, address FROM pg_hba_file_rules WHERE 'replication' = ANY(database);"
```
✅ 실측: `10.10.10.24/32`(자기 자신) 규칙만 있고 `10.10.10.13/32`는 없는 것을 확인.

```bash
echo "host    replication     replicator      10.10.10.13/32       scram-sha-256" | \
  sudo tee -a /pgdata/data/pg_hba.conf
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```
> `restart`가 아니라 `pg_reload_conf()`를 쓰는 이유: db02는 지금 실제 서비스 중인 Primary라 재시작 없이 설정만 다시 읽게 하는 편이 안전합니다(`pg_hba.conf` 변경은 reload로 충분히 반영됩니다).

> ⚠️ **순서 주의**: 이 pg_hba.conf 규칙은 반드시 3)의 `pg_basebackup`을 실행하기 **전에** db02 쪽에서 먼저 반영돼 있어야 합니다. (실제 진행 시 db02 터미널에서 이 작업을 먼저 마친 뒤 db01 터미널로 넘어갔습니다.)

**3) db01에서 db02를 향해 `pg_basebackup`** — §11-7과 동일한 패턴, `-h`만 db02(`10.10.10.24`)로, 슬롯 이름만 새로(`db02_slot`은 예전 방향에서 이미 쓰인 이름이므로 `db01_slot`으로 구분):

🖥️ **db01**에서:
```bash
sudo -u postgres env PGPASSWORD='<REPLICATION_PASSWORD>' pg_basebackup \
  -h 10.10.10.24 -U replicator \
  -D /pgdata/data \
  -P -v -X stream -C -S db01_slot -R
```
> ⚠️ **`<REPLICATION_PASSWORD>`는 자리표시자입니다 (v16 r24, 실제로 겪음)** — 꺾쇠까지 그대로 두고 따옴표도 없이 입력하면 셸이 `<`를 입력 리다이렉트로 해석해서 `-bash: REPLICATION_PASSWORD: No such file or directory`가 나고 명령은 실행되지 않습니다(무해). §11-6에서 정한 실제 비밀번호를 `PGPASSWORD='<REPLICATION_PASSWORD>'`처럼 따옴표로 감싸 넣으세요(체크리스트 84번).

(계정 `replicator`와 비밀번호는 §11-6에서 만든 것 그대로 사용합니다 — db02는 db01을 복제해 만들어졌으므로 이 계정이 이미 db02에도 그대로 있습니다. 새로 만들 필요 없습니다.)

✅ 실측: `checkpoint completed` → `created replication slot "db01_slot"` → `100%` 전송 → `base backup completed`까지 에러 없이 완료.

재현 기록(2026-10-05, v16 r24): `write-ahead log start point: 0/9000028 on timeline 2` → `30937/30937 kB (100%)` → `write-ahead log end point: 0/9000100` → `base backup completed`.

**4) `listen_addresses` 정정** — §11-11에서 겪었던 문제가 반대 방향으로 그대로 재현됩니다. `pg_basebackup`이 db02의 `postgresql.conf`를 통째로 복사해오기 때문에 `listen_addresses`에 db02 자신의 IP(`10.10.10.24`)가 그대로 들어있습니다.

🖥️ **db01**에서:
```bash
sudo grep listen_addresses /pgdata/data/postgresql.conf
sudo sed -i "s/10.10.10.24/10.10.10.13/" /pgdata/data/postgresql.conf
sudo grep listen_addresses /pgdata/data/postgresql.conf   # localhost,10.10.10.13 이어야 함
```
✅ 실측: `localhost,10.10.10.24` → `localhost,10.10.10.13`으로 정상 정정 확인.

**5) SELinux 컨텍스트 재적용** — 새로 만든 디렉터리이므로 §6-5에서 걸어둔 규칙을 다시 적용합니다:
```bash
sudo restorecon -Rv /pgdata/data
```

**6) 기동**

🖥️ **db01**에서:
```bash
sudo systemctl start postgresql
sudo -u postgres psql -Atc "SELECT pg_is_in_recovery();"    # t 여야 정상(Standby로 붙음)
```
✅ 실측: `t` 확인. 이어서 기존 `promote_test` 2행(§12에서 만든 것)이 그대로 조회돼, 백업 자체가 온전했다는 것도 함께 확인했습니다.

재현 기록(2026-10-05, v16 r24): 기동 직후 `pg_last_wal_receive_lsn = pg_last_wal_replay_lsn = 0/A0001C0`이었고, `promote_test`에는 §13-3에서 db02에 넣은 두 건(08:48:20, 08:48:32)까지 포함해 08:35:07 포함 3행이 보였습니다.

### 13-3. 검증 — ✅ 완료 (진행 중 실제로 겪은 문제 포함)

🖥️ **db02**에서 (db01이 새 Standby로 붙었는지 확인):
```bash
sudo -u postgres psql -xc "SELECT client_addr, state, sync_state FROM pg_stat_replication;"
```
✅ 실측: `client_addr: 10.10.10.13` / `state: streaming` / `sync_state: async` 확인.

**실제로 겪은 문제 — INSERT가 성공 메시지를 냈는데도 db02 자신에게서조차 사라짐**

"가장 확실한 증거"로 db02에 `INSERT INTO promote_test VALUES (now());`를 실행했더니 `INSERT 0 1`까지 정상 출력됐습니다. 그런데 db01에서 조회해도, **db02 자기 자신에게서 다시 조회해도** 그 값이 없었고, db02의 `pg_current_wal_lsn()`도 그 INSERT 전후로 전혀 움직이지 않았습니다.

처음엔 "db01이 복제를 못 따라간다"고 의심하고 `pg_stat_wal_receiver`/`pg_stat_replication`의 LSN을 비교했지만, **db01은 이미 db02와 완전히 같은 LSN**이었습니다 — 즉 db01 문제가 아니라, db02에서 그 트랜잭션 자체가 커밋까지 못 가고 사라진 것으로 좁혀졌습니다.

```bash
# db02에서 INSERT와 확인을 같은 세션에 묶어서 실행 → 재현 안 됨(정상 동작)
sudo -u postgres psql -c "INSERT INTO promote_test VALUES (now()) RETURNING t;" \
                      -c "SELECT pg_current_wal_lsn();" \
                      -c "SELECT * FROM promote_test ORDER BY t DESC;"
```
이렇게 한 세션 안에서 INSERT→LSN 확인→SELECT를 붙여서 실행하니 문제없이 재현됐고(`RETURNING`이 즉시 새 값을 보여주고, LSN도 실제로 전진하고, `pg_stat_user_tables.n_tup_ins`도 정확히 일치), 이후로는 재발하지 않았습니다. 정확한 원인은 확정하지 못했지만(의심 후보: 세션이 각 `-c` 사이에서 트랜잭션을 미완료 상태로 남기고 접속을 끊을 때 자동 롤백되는 경우 등), **앞으로는 쓰기와 확인용 조회를 별도 명령으로 나누지 않고 한 세션에 묶어서 실행**하는 습관으로 우회했습니다.

> 💡 **진단에 쓴 핵심 개념 — LSN(Log Sequence Number)**: initdb 이후 쌓인 WAL 전체를 하나의 끊김 없는 바이트 스트림으로 봤을 때의 절대 위치를 나타내는 값입니다(`상위32비트/하위32비트`, 16진수 표기, 예: `0/E000410`). `pg_current_wal_lsn()`(Primary가 지금까지 쓴 지점), `pg_last_wal_receive_lsn()`/`pg_last_wal_replay_lsn()`(Standby가 받은/반영한 지점), `pg_stat_replication`의 `sent_lsn`/`replay_lsn`을 서로 비교하면 복제 지연을 "초 단위 시간"이 아니라 "정확한 바이트 수"로 잴 수 있습니다. 이번 사례에서 이 비교 덕분에 "복제 지연 문제"가 아니라 "db02에서 커밋이 안 된 문제"라는 걸 정확히 좁혀낼 수 있었습니다.

재현 기록(2026-10-05, v16 r24): 이 PC에서는 위 증상이 **재현되지 않았습니다** — `INSERT … RETURNING t`를 한 세션에 묶은 명령도, 이어서 실행한 단독 `INSERT INTO promote_test VALUES (now());`도 정상이었고 db01에서 두 건 모두 조회됐습니다. 원인을 확정하지 못한 채 남은 항목입니다.

**최종 확인** (문제 해결 후, 새 INSERT로 재검증):

🖥️ **db02**에서:
```bash
sudo -u postgres psql -c "INSERT INTO promote_test VALUES (now());"
```
🖥️ **db01**에서 (곧바로):
```bash
sudo -u postgres psql -xc "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
sudo -u postgres psql -c "SELECT * FROM promote_test ORDER BY t DESC LIMIT 3;"
```
✅ 실측: db01의 `receive_lsn`/`replay_lsn`이 `0/E000530`으로 완전히 일치(지연 없음), 방금 db02에 넣은 값(`03:48:52...`)이 db01에서도 그대로 조회됨 — **db01→db02(구조상으론 db02→db01) 재동기화 완전히 검증 완료**.

### 13-4. (권장) 다음 페일오버 연습부터는 진짜 `pg_rewind`를 쓸 수 있게 준비 — ✅ 완료

13-1에서 확인했듯 이번엔 조건이 안 맞아 `pg_basebackup`으로 우회했지만, 앞으로 또 승격 연습을 할 계획이라면 지금 두 노드 모두 `wal_log_hints`를 켜두는 게 좋습니다. 다음번 갈라짐부터는 블록 단위로만 복사하는 진짜 `pg_rewind`를 쓸 수 있습니다.

**Standby(db01)부터 먼저** (위험 없는 쪽):
```bash
echo "wal_log_hints = on" | sudo tee -a /pgdata/data/postgresql.conf
sudo systemctl restart postgresql
sudo -u postgres psql -Atc "SELECT pg_is_in_recovery();"    # t 확인
```

**실제로 겪은 문제 — `pg_controldata`의 "OO setting" 항목은 `SHOW`가 보여주는 라이브 설정이 아니라서, Standby만 켜서는 `off`로 남음 (v16 r24 설명 수정)**

재시작 후 확인해보니:
```bash
sudo -u postgres /usr/bin/pg_controldata /pgdata/data | grep wal_log_hints
```
```
wal_log_hints setting:                off      # 재시작했는데도 여전히 off!
```

`SHOW`로 라이브 값을 먼저 확인해보면 문제가 없다는 게 드러납니다:
```bash
sudo -u postgres psql -Atc "SHOW wal_log_hints;"   # → on (설정은 정상 적용됨)
```

**원인 (v16 r24 수정)**: `pg_controldata`가 보여주는 "OO setting" 항목들(`wal_level setting`, `wal_log_hints setting`, `max_connections setting` 등)은 `SHOW`가 보여주는 라이브 값이 아니라 `pg_control` 파일에 기록된 값입니다. 이전 가이드는 이것을 '마지막 checkpoint/restartpoint 시점의 스냅샷이고 Standby에서 `CHECKPOINT;`로 갱신된다'고 설명했지만, 이번 재현에서는 **그 설명이 맞지 않았습니다** — db01(Standby)에서 `CHECKPOINT;`를 실행한 뒤 2초 간격으로 두 번 확인해도 `off`였습니다. 반면 아래 'Primary(db02)' 단계로 db02에도 `wal_log_hints = on`을 넣고 재시작한 뒤에는, db01에서 `sleep 5` 후 별도 조작 없이 `on`이 됐습니다. 그래서 현재의 **추정**은 'Standby의 이 값은 Primary가 기동하면서 남기는 파라미터 변경 WAL 레코드를 재생할 때 갱신된다'는 것입니다(PostgreSQL 동작 원리에 따른 추정이며 WAL 레코드를 직접 확인하지는 않았습니다). Primary가 아직 `off`인 동안 Standby만 켜서는 `pg_controldata`가 `on`으로 바뀌지 않는 것은 이 환경에서 확인한 사실입니다.

**해결 (v16 r24 수정)**: Standby 쪽에서 따로 할 일은 없습니다 — 아래 'Primary(db02)' 단계를 마친 뒤 db01에서 다시 확인합니다(결과는 그 단계 끝에 적었습니다). `CHECKPOINT;`는 이번엔 효과가 없었습니다(재현 기록: `CHECKPOINT;` 뒤 2초 간격 두 번 모두 `off`). 그 시점에 `SHOW wal_log_hints;`가 `on`이면 설정 자체는 정상 적용된 것입니다.

> 💡 **이건 13-1의 pg_rewind 사전 점검에도 그대로 적용됩니다** — pg_rewind는 라이브 GUC가 아니라 `pg_controldata`가 보여주는 `pg_control`의 값을 검사하므로, `SHOW wal_log_hints;`가 `on`이어도 `pg_controldata`가 `off`면 조건을 충족한 상태가 아닙니다. 준비가 끝났는지는 `pg_controldata` 쪽으로 확인하세요(v16 r24: 'Standby에서 `CHECKPOINT;`로 강제 반영'이라는 이전 설명은 철회).

**이어서 Primary(db02)** — 재시작 순간 잠깐 서비스가 끊기니 트래픽 없는 시점에:
```bash
echo "wal_log_hints = on" | sudo tee -a /pgdata/data/postgresql.conf
sudo systemctl restart postgresql
sudo -u postgres /usr/bin/pg_controldata /pgdata/data | grep wal_log_hints    # on 확인
```
✅ 실측: Primary는 재시작 직후 곧바로 `on`으로 확인됨(재현 기록 2026-10-05도 같음).

> ⚠️ 위 `echo … | sudo tee -a`는 **한 번만** 실행하세요(v16 r24). 두 번 실행하면 같은 줄이 두 번 들어갑니다(같은 값이라 동작에는 지장이 없습니다). `grep -n '^wal_log_hints' /pgdata/data/postgresql.conf`로 확인하고 중복이면 `sudo vi`로 한 줄을 지우세요. 재현 기록: db02에서 이 명령과 재시작을 두 번 실행했고 두 번 모두 복제는 `streaming`으로 돌아왔습니다(2026-10-05 확인, v16 r25: db02에서 `grep -n '^wal_log_hints' /pgdata/data/postgresql.conf`가 831행과 832행 모두 `wal_log_hints = on`을 보여줘 중복이 실제로 있었습니다. 같은 값이라 동작에는 지장이 없고 정리는 선택입니다. 지우려면 `sudo -u postgres sed -i '832{/^wal_log_hints = on$/d}' /pgdata/data/postgresql.conf` — postgres 계정으로 실행해야 파일 소유자가 바뀌지 않고, 값이 같아 재시작은 필요 없다고 보지만 **미실행**).

**마지막으로 db02 재시작 후 db01이 다시 잘 붙었는지 확인**:
```bash
sudo -u postgres psql -xc "SELECT client_addr, state FROM pg_stat_replication;"
```
✅ 실측: `client_addr: 10.10.10.13` / `state: streaming` — 정상 재연결 확인. db01·db02 양쪽 모두 `wal_log_hints: on`이 되어, 다음번 승격 연습부터는 진짜 `pg_rewind`를 쓸 수 있는 상태입니다.

🖥️ **db01**에서 (db02 재시작 몇 초 뒤, v16 r24):
```bash
sleep 5
sudo -u postgres /usr/bin/pg_controldata /pgdata/data | grep wal_log_hints    # on
```
재현 기록(2026-10-05): `on`이었습니다. 이 확인 전까지 db01은 `off`였고 `CHECKPOINT;`로도 바뀌지 않았습니다. 여기서도 `off`면 몇 초 더 기다렸다가 다시 확인하고, 그래도 `off`면 위 추정이 이 환경에서 맞지 않는 것이니 `pg_controldata`와 `SHOW wal_log_hints;` 결과를 함께 기록해 두세요.

### 13-5. 정리

| 항목 | §12 끝(재동기화 전) | §13 끝(재동기화 후, 실측) |
|---|---|---|
| db01 | 정지, 예전 타임라인(1) | db02의 새 Standby로 재구성, 스트리밍 중, `wal_log_hints on` |
| db02 | Primary(타임라인 2) | 그대로 Primary, `wal_log_hints on` |
| 복제 관계 | 끊어짐 | db02 → db01로 재연결, LSN 완전 일치 확인 |
| `pg_rewind` 준비 상태 | 조건 미충족 | 양쪽 모두 충족 — 다음번 갈라짐부터 사용 가능 |

재현 기록(2026-10-05, v16 r24): db02 → db01이 `streaming`/`async`(수신·리플레이 LSN `0/A0001C0` 일치)였고 양쪽 `pg_controldata`의 `wal_log_hints setting`이 `on`이었습니다. `pg_rewind`를 실제로 실행해 본 것은 아닙니다.

추가 확인(2026-10-05, v16 r25): db01에서 `sudo ss -tlnp | grep 5432`가 `10.10.10.13:5432`, `127.0.0.1:5432`, `[::1]:5432`에서 postgres 프로세스가 LISTEN 중임을 보여줬습니다.

> 💡 **실전 메모**: 같은 인프라를 여러 세션(다른 채팅창, 다른 도구)에서 동시에 만지면 서로 다른 상태를 전제로 다음 작업을 준비하게 될 수 있습니다. 이번 세션 도중에도 다른 세션이 "db01은 아직 정지 상태"라는 §12 시점 전제로 스냅샷 복원 명령을 준비해둔 걸 실행 직전에 발견했습니다. 여러 창을 같이 쓸 땐 실제로 명령을 실행하는 창구를 하나로 정해두거나, 세션을 옮길 때마다 최신 상태를 서로 알려주는 게 안전합니다.

---

