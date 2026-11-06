> 이 문서는 `3tier-rocky10-guide-v16.md` 의 1940~2808줄을 그대로 옮긴 것이다. 비밀번호와 로컬 경로만 자리표시자로 바꿨다.

## 9. Phase 2 시작하기 — web02/was02 이중화(HA)

Phase 1의 §7 End-to-End 테스트 5단계가 전부 통과한 뒤 시작하세요. Phase 2는 web02/was02 노드를 추가해 Pacemaker+Corosync로 HA를 구성하고, 이후 Redis 캐시·세션 공유, DW 스키마, Ansible 전환까지 이어지는 로드맵입니다. db01은 Phase 2에서 손대지 않습니다(HA는 web/was 계층만 우선 적용, DB 이중화는 별도 로드맵).

> **이 챕터를 보는 법**: 아래 모든 명령 블록 바로 위에 🖥️ 로 "어느 서버에서 실행하는지"를 명시했습니다. 여러 서버 창을 동시에 띄워놓고 작업하다 보면 다른 서버 창에 잘못 붙여넣는 실수가 나기 쉬우니, 명령을 붙여넣기 전에 터미널 프롬프트(`[vagrant@web01 ~]$` 등)와 🖥️ 표시가 서로 맞는지 한 번씩 확인하세요.

### 9-1. Vagrantfile에 web02 / was02 추가

기존 `NODES` 해시에 아래 두 항목을 추가합니다(db01은 그대로 둡니다):
```ruby
NODES = {
  "web01" => { ip_mgmt: "192.168.10.111", mem: 2048, cpu: 2, extra_disks: [] },
  "web02" => { ip_mgmt: "192.168.10.121", mem: 2048, cpu: 2, extra_disks: [] },
  "was01" => { ip_mgmt: "192.168.10.112", mem: 2048, cpu: 2, extra_disks: [] },
  "was02" => { ip_mgmt: "192.168.10.122", mem: 2048, cpu: 2, extra_disks: [] },
  "db01"  => { ip_mgmt: "192.168.10.113", mem: 2560, cpu: 2,
    extra_disks: [ { name: "pgdata", size: 20 }, { name: "pgwal", size: 5 }, { name: "pgbackup", size: 5 } ]
  }
}
```

| 서버 | 관리망 IP | bond0(서비스망) IP |
|---|---|---|
| web02 | 192.168.10.121 | 10.10.10.21/24 |
| was02 | 192.168.10.122 | 10.10.10.22/24 |

> ⚠️ **v16 정정**: web02=`10.10.10.21`, was02=`10.10.10.22`는 **새 노드의 고유 주소**입니다. v15의 §3-5는 web01/was01 bond0에도 `.21/.22`를 세컨더리로 붙이게 해서 IP가 충돌했습니다(재현 세션에서 web02→web01 방향만 통신 불가로 나타남). v16의 §3-5는 web01/was01에 기본 IP 하나만 주며, 이미 옛 방식으로 만들었다면 아래 9-2의 **0) 사전 점검**에서 제거합니다.

> ℹ️ **주소 체계 참고**: 애초 계획은 web02=10.10.10.14, was02=10.10.10.15를 노드 자체 IP로 쓰고 10.10.10.21/22는 나중에 VIP용으로 비워두는 것이었지만, 실제 클러스터 구성 때 21/22를 그대로 노드 주소로 썼습니다(경위는 위 v6 업데이트 참고). 이 문서는 **실제 값 기준**으로 통일했고, 앞으로 등록할 VIP는 10.10.10.14/15를 쓰는 것으로 계획을 조정했습니다(§9-9).

🖥️ 호스트 PC에서:
```bash
vagrant up web02 was02
```

web02/was02에는 §3(공통 초기 설정) 중 **3-1(호스트명)·3-2(/etc/hosts)·3-3(관리망)·3-4(dnf 기본 도구)**까지 동일하게 적용하세요. **서비스망 bond0 구성(원래 §3-5)은 IP 체계가 다르므로 아래 9-2에서 별도로 진행합니다.** 그 이후 web02는 §4(web01과 동일), was02는 §5(was01과 동일)를 반복하면 됩니다.

### 9-2. 서비스망 bond0 구성 — web02 / was02

**왜 이 단계가 따로 필요한가**: 9-1의 안내대로 §4/§5만 반복하면 Apache/Tomcat 설정은 되지만, 정작 노드 간 통신에 쓰이는 bond0(원래 §3-5)이 빠집니다. 실제로 이 단계를 건너뛴 채 클러스터를 구성했다가 `ip -4 addr show bond0` → `Device "bond0" does not exist`로 확인된 적이 있습니다. **web02/was02를 새로 올리셨다면 아래를 §3-5 대신 반드시 먼저 실행하세요.**

**0) 사전 점검 — web01/was01에 `.21`/`.22`가 남아 있지 않은지 (v16 신설, 가장 중요)**

web02=`10.10.10.21`, was02=`10.10.10.22`는 **새 노드의 고유 주소**입니다. v15 이하의 §3-5를 그대로 따라 web01/was01을 만들었다면 그 bond0에 `.21`/`.22`가 세컨더리로 붙어 있어 새 노드와 IP가 충돌합니다(v16 업데이트 1번).

🖥️ web01, was01 **각각에서**:
```bash
ip -4 addr show bond0 | grep -E 'inet 10\.10\.10\.2[12]/' && echo "❌ 충돌 주소 있음 → 아래로 제거" || echo "✅ 없음(정상) → 1)로"
```
❌가 나오면:

🖥️ web01에서:
```bash
sudo ip addr del 10.10.10.21/24 dev bond0                      # 지금 바로 반영(무중단 — SSH는 NAT 망이라 안 끊깁니다)
sudo nmcli con mod bond0 ipv4.addresses "10.10.10.11/24"       # 재부팅 후에도 유지되게 저장
```
🖥️ was01에서:
```bash
sudo ip addr del 10.10.10.22/24 dev bond0
sudo nmcli con mod bond0 ipv4.addresses "10.10.10.12/24"
```
이미 web02/was02에서 ping이 실패한 뒤라면, 실패(`FAILED`) 기록이 이웃 캐시에 남아 있으니 한 번 비웁니다:

🖥️ web02, was02 **각각에서**:
```bash
sudo ip neigh flush dev bond0
```

**1) 물리 NIC 이름 확인**

🖥️ web02에서 (was02는 뒤에 동일한 순서로):
```bash
ip link show
```
`enp0s8`(관리망, 이미 IP 잡혀 있음) 외에 UP 상태인데 IP가 없는 NIC 2개(대개 `enp0s9`, `enp0s10`)가 서비스망용입니다. VM마다 번호가 다를 수 있으니 실제 출력값을 확인하세요. 이름이 다르면 아래 블록 안의 두 줄(`ifname enp0s9`, `ifname enp0s10`)만 바꿉니다.

**2) bond0 생성 — web02와 was02가 똑같은 블록을 붙여넣습니다 (v16)**

IP는 **호스트명**(`web02` → `.21`, `was02` → `.22`)으로 자동 결정되므로, v15처럼 두 서버 블록을 따로 두고 IP만 바꾸는 방식에서 나던 복붙 사고가 없습니다. 먼저 호스트명이 맞는지 확인하세요(`vagrant up`이 타임아웃으로 끝났다면 `localhost.localdomain`일 수 있습니다 — §3-1):
```bash
hostname            # web02 / was02 여야 함. 아니면: sudo hostnamectl set-hostname web02  (was02도 동일)
```

🖥️ web02, was02 **각각에서** — 먼저 root 셸로 들어간 뒤(`sudo -i`는 따로 실행), 아래 블록을 붙여넣습니다:
```bash
sudo -i
```
```bash
# 이 블록은 서버마다 고칠 곳이 없습니다 — 어느 서버 창에서든 그대로 붙여넣으세요.
# bond0 IP는 '호스트명'으로 자동 결정되므로, 다른 서버의 IP를 잘못 넣는 실수가 원천적으로 사라집니다.
HN=$(hostname -s)
case "$HN" in
  web01)     BOND_IPS="10.10.10.11/24" ;;
  was01)     BOND_IPS="10.10.10.12/24" ;;
  db01)      BOND_IPS="10.10.10.13/24,10.10.10.23/24" ;;   # .23 = 예약된 서비스 IP (§16에서 db_vip가 됨)
  web02)     BOND_IPS="10.10.10.21/24" ;;
  was02)     BOND_IPS="10.10.10.22/24" ;;
  db02)      BOND_IPS="10.10.10.24/24" ;;
  witness01) BOND_IPS="10.10.10.25/24" ;;
  *)         BOND_IPS="" ;;
esac

if [ -z "$BOND_IPS" ]; then
  echo "❌ 호스트명($HN)이 목록에 없습니다 → §3-1의 hostnamectl set-hostname부터 하세요."
else
  echo "▶ $HN 의 bond0 IP = $BOND_IPS"
  # 이미 있는 프로파일은 다시 만들지 않습니다(재실행해도 중복 프로파일이 생기지 않음)
  nmcli -g NAME con show | grep -qx bond0        || nmcli con add type bond ifname bond0 con-name bond0 bond.options "mode=active-backup,miimon=100"
  nmcli con mod bond0 ipv4.addresses "$BOND_IPS" ipv4.gateway 10.10.10.1 ipv4.method manual ipv6.method disabled
  nmcli -g NAME con show | grep -qx bond0-port1  || nmcli con add type ethernet ifname enp0s9  master bond0 con-name bond0-port1
  nmcli -g NAME con show | grep -qx bond0-port2  || nmcli con add type ethernet ifname enp0s10 master bond0 con-name bond0-port2

  nmcli con up bond0-port1 || echo "(첫 슬레이브 활성화 에러는 무시해도 됩니다 — 아래에서 다시 올립니다)"
  nmcli con up bond0-port2
  nmcli con up bond0
  nmcli con up bond0-port1 || echo "(재시도 에러는 아래 ✅ 확인이 통과하면 무시해도 됩니다)"   # bond0이 올라온 뒤라 보통은 여기선 성공합니다(이미 붙어 있으면 그냥 통과)
fi
```
> `nmcli con up bond0-port1`의 `A dependency of the connection failed`는 §3-5의 설명대로 무시해도 됩니다(블록이 자동으로 재시도합니다). 이 두 노드에서는 재현 세션에서 나오지 않았지만 나와도 정상 범위입니다.

**3) 로컬 확인**

🖥️ web02, was02 각각에서 (같은 셸에서 이어서 — `BOND_IPS` 변수가 살아 있어야 함):
```bash
GOT=$(ip -4 -o addr show bond0 | awk '{print $4}' | sort | paste -sd,)
WANT=$(echo "$BOND_IPS" | tr ',' '\n' | sort | paste -sd,)
[ "$GOT" = "$WANT" ] && echo "✅ bond0 IP 일치: $GOT" || echo "❌ 불일치 — 현재 [$GOT] / 기대 [$WANT]  → 위 블록을 그대로 다시 실행하세요"
grep -E 'Bonding Mode|Currently Active Slave|Slave Interface|MII Status' /proc/net/bonding/bond0
```
`✅`와 함께 슬레이브 2개 모두 `MII Status: up`이어야 정상입니다.

**4) 노드 간 통신 확인 — 여기서 실패하면 클러스터는 100% 실패합니다**

> ⚠️ **`ping`만으로는 부족합니다 (v16).** 상대 주소가 **내 자신의 주소**이면 ping이 케이블에 나가지도 않고 로컬에서 응답해 '성공'으로 보입니다 — 재현 세션에서 web01이 `ping 10.10.10.21`을 했을 때 응답이 `time=0.113 ms`로 나온 것이 바로 이 경우였습니다(web01이 `.21`을 세컨더리로 갖고 있었음). 그래서 각 방향마다 먼저 `ip route get`으로 "진짜로 bond0를 타고 나가는지"를 확인하고, ping 뒤에는 이웃 테이블에 상대의 MAC이 실제로 잡혔는지도 봅니다.

🖥️ web01에서:
```bash
ip route get 10.10.10.21    # 정상: "10.10.10.21 dev bond0 src 10.10.10.11 ..."   비정상: "local 10.10.10.21 dev lo ..." (= 내 주소 = 충돌)
ping -c 3 10.10.10.21
ip neigh show 10.10.10.21   # 정상: lladdr 08:00:27:.. REACHABLE(또는 STALE)   비정상: FAILED
```
🖥️ web02에서:
```bash
ip route get 10.10.10.11
ping -c 3 10.10.10.11
ip neigh show 10.10.10.11
```
🖥️ was01에서:
```bash
ip route get 10.10.10.22
ping -c 3 10.10.10.22
ip neigh show 10.10.10.22
```
🖥️ was02에서:
```bash
ip route get 10.10.10.12
ping -c 3 10.10.10.12
ip neigh show 10.10.10.12
```
4개 방향 전부 ① `ip route get`이 `dev bond0`로 나가고 ② `0% packet loss`이며 ③ `ip neigh`가 `FAILED`가 아니어야 다음 단계로 넘어갈 수 있습니다. 실패하면 이 순서로 봅니다: **(a) 위 0)의 중복 주소** → (b) bond0 자체가 안 만들어졌거나 슬레이브가 down(3)) → (c) Vagrantfile의 intnet 이름(`svc-net`)이 서버마다 다른 것(1)로 돌아가세요).

> **참고 — 이 문제를 겪었을 때 원인을 찾느라 확인·배제한 것들 (v16, 실제 기록)**: `arp_ignore`/`arp_filter`(둘 다 0), firewalld 중지 후 재시험, bond0 슬레이브 상태, 잔여 `Wired connection N` 프로파일 조사가 전부 원인이 아니었고, `nmcli connection delete`로 프로파일을 지우다 SSH 세션이 멈추는 사고까지 났습니다(체크리스트 49번). 결정적 단서는 web01 `ip a show bond0`의 세컨더리 `.21`과 ping 응답의 비정상적인 속도였습니다. 한 방향만 실패하는 증상은 튜닝 파라미터를 만지기 전에 **양쪽 주소가 겹치지 않는지**부터 확인하세요.

### 9-3. 클러스터 패키지를 폐쇄망 저장소에 채워넣기

**미리 알아야 할 것 — 처음 방식대로 하면 왜 실패하는가**

1. `dnf install --downloadonly`는 **이미 설치된 패키지는 아예 다운로드하지 않습니다.** web01엔 pacemaker/corosync/pcs/resource-agents가 이미 설치돼 있어서, web01에서 이 명령을 아무리 반복해도 "Nothing to do"로 끝나고 실제 rpm은 저장소에 하나도 안 채워집니다.
2. pacemaker/corosync/pcs/resource-agents는 Rocky Linux 10의 BaseOS/AppStream이 아니라 **별도의 `highavailability` 저장소**에 있고, 기본적으로 비활성화되어 있습니다.

이 두 가지 때문에 web01에서 아무리 시도해도 로컬 저장소(`/repo/rocky10/local`)의 실제 rpm 개수가 0에 가까운 상태가 됩니다. 아래는 **이미 설치된 게 없는 web02**를 이용해 진짜 패키지를 내려받아 web01의 저장소로 옮기는, 실제로 검증된 절차입니다.

**1) web02에서 highavailability 저장소 활성화 + 전체 다운로드**

🖥️ web02에서:
```bash
sudo dnf config-manager --set-enabled highavailability
dnf repolist enabled | grep -i high   # highavailability가 떠야 정상

mkdir -p /tmp/ha-pkgs
sudo dnf install --downloadonly --downloaddir=/tmp/ha-pkgs \
  pacemaker corosync pcs resource-agents bc -y

ls /tmp/ha-pkgs/*.rpm | wc -l   # 100개 이상이어야 정상 (재현 기록: 110개, 27 MB)
```
> (v16 정정) 개수는 `ls -la … | wc -l`이 아니라 위처럼 `*.rpm`만 세세요. `ls -la`는 `total` 줄과 `.`, `..`까지 3줄을 더해 재현 기록에서 113으로 나왔고, 가이드 예전 문구의 '111개'도 맞지 않았습니다(실제 rpm은 110개).
>
> pacemaker/corosync/pcs/resource-agents/bc 5개만 요청했는데도 libknet1, corosynclib, lvm2, perl-*, ruby-* 등 100개가 넘는 의존성이 함께 딸려옵니다 — 정상입니다. web02엔 아무것도 안 깔려 있어서 dnf가 진짜 전체 의존성 트리를 계산하기 때문입니다.

> (v16 r20) 위 `--downloadonly --downloaddir`로 받은 `/tmp/ha-pkgs`의 rpm은 §4-6 ⚠️ 2)와 같은 이유로, web02에서 패키지를 설치하는 `dnf` 작업(아래 8)의 web02 블록)이 성공하면 지워질 수 있습니다. web01로 복사해 온 뒤에는 상관없지만 **3)에서 web01로 받기 전에는 web02에서 설치 작업을 하지 마세요.** 실제로 지워졌는지는 확인하지 못했습니다(**미확인**).

**2) web02에서 임시 HTTP 서버로 공유**

🖥️ web02에서:
```bash
cd /tmp/ha-pkgs
python3 -m http.server 8080 &

sudo firewall-cmd --add-port=8080/tcp   # --permanent 없이 임시로만
```

**3) web01에서 받아오기**

🖥️ web01에서:
```bash
mkdir -p /tmp/ha-pkgs && cd /tmp/ha-pkgs
wget -m -np -nd -A "*.rpm" http://10.10.10.21:8080/
ls *.rpm | wc -l   # web02와 같은 개수가 나와야 정상 (재현 기록: 110)
```

> (v16 정정) wget이 마지막에 찍는 `Downloaded: 111 files, 27M`의 111은 rpm 개수가 아닙니다 — 목록을 읽으려고 받은 `index.html`이 포함된 숫자라서 rpm 110개보다 1 큽니다(`-A "*.rpm"`이라 이 파일은 받은 뒤 지워집니다). 기준은 `ls *.rpm | wc -l`이고 web02의 `ls /tmp/ha-pkgs/*.rpm | wc -l`과 같으면 됩니다. 재현 기록에서는 같은 명령을 한 번 더 실행했을 때 모든 파일이 `304 Not Modified … Omitting download`로 건너뛰어졌고 개수는 그대로 110이었습니다(다시 실행해도 안전합니다).

**4) web01 저장소에 반영 + 메타데이터 재생성**

🖥️ web01에서:
```bash
sudo mv /tmp/ha-pkgs/*.rpm /repo/rocky10/local/
sudo createrepo_c /repo/rocky10/local
```
> 기존 저장소가 이미 있어도 `--update`가 아니라 옵션 없이(전체 재생성) 실행하는 걸 권장합니다 — 중간에 메타데이터가 꼬여 있었을 경우(빈 패키지 목록 등) `--update`는 그 오류를 그대로 이어받습니다.
>
> (v16 r20) `createrepo_c`가 찍는 `Directory walk done - N packages`의 N을 §4-6 끝에서 기록한 개수와 비교해 보세요. 재현 기록(2026-10-02)은 **475개**(= §4-6 의존성 429 + 이 단계의 HA 전용 46)였습니다. 이 단계에서 `mv`하는 110개 중 §4-6에서 이미 받은 것과 이름이 같은 64개는 덮어써지므로 N은 '기록한 개수 + 110'이 아니라 '기록한 개수 + 46'에 가깝습니다(이 PC 기준; 시점에 따라 겹치는 수는 달라질 수 있음).

**5) SELinux 컨텍스트 복구 (중요 — 안 하면 403)**

🖥️ web01에서:
```bash
sudo restorecon -Rv /repo/rocky10/local/
```
> `mv`는 파일을 옮길 때 원래 있던 위치(`/tmp`)의 SELinux 컨텍스트를 그대로 유지합니다. `/repo`가 요구하는 `httpd_sys_content_t`가 아니라서 Apache가 403 Forbidden으로 막습니다. `restorecon`이 `/repo` 경로에 이미 지정된 정책대로 컨텍스트를 다시 맞춰줍니다.

**6) web01에서 최종 확인**

🖥️ web01에서:
```bash
f=$(basename /repo/rocky10/local/corosync-3*.rpm)   # 파일명의 버전이 시점마다 달라서 직접 쓰지 않고 찾아 씁니다
echo "$f"
curl -I http://192.168.10.111/repo/rocky10/local/$f
curl -I http://192.168.10.111/repo/rocky10/local/repodata/repomd.xml
```
둘 다 `HTTP/1.1 200 OK`가 나와야 성공입니다.

> (v16 정정) 예전 가이드는 `corosync-3.1.10-1.el10_2.1.x86_64.rpm`이라는 파일명을 그대로 적었는데, 2026-10-01 재현에서 받은 파일은 `corosync-3.1.10-1.el10_2.2.x86_64.rpm`이었습니다. 고정 파일명으로는 `404 Not Found`가 날 수 있습니다. `403`이면 5)의 `restorecon`을 안 한 것입니다.

**7) 임시로 열었던 것 정리**

🖥️ web02에서:
```bash
fg          # python3 -m http.server를 포그라운드로 가져온 뒤 Ctrl+C로 종료
sudo firewall-cmd --remove-port=8080/tcp
```

**8) 4대 전부에서 실제 설치 — 노드마다 방법이 다릅니다 (v16 정정)**

pacemaker 계열은 `highavailability` 저장소(기본 꺼짐) 또는 4)에서 채운 로컬 저장소에만 있어서, 네 대에 같은 명령을 그대로 붙여넣으면 저장소 설정이 다른 노드는 `No match for argument: pacemaker`로 실패합니다. 먼저 네 대 각각에서 현재 상태를 확인하세요.

🖥️ web01, was01, web02, was02 **각각**에서:
```bash
rpm -q pacemaker corosync pcs resource-agents   # 이미 설치돼 있으면 버전 4줄, 아니면 `is not installed`
dnf repolist                                    # 켜져 있는 저장소 확인
```

그다음 노드별로 아래 중 해당하는 블록을 실행합니다.

🖥️ **was01** — `local-web01`이 §4-6에서 이미 등록돼 있습니다(`dnf repolist`에 `local-web01`만 보임):
```bash
sudo dnf clean metadata
sudo dnf install -y pacemaker corosync pcs resource-agents
```

🖥️ **web02** — 1)에서 `highavailability`를 켜 둔 상태라 그 저장소에서 바로 설치됩니다. 이후 §10-2-1에서 httpd를 baseos/appstream에서 받으므로 web02는 외부 저장소를 끄지 않습니다:
```bash
sudo dnf install -y pacemaker corosync pcs resource-agents
```

🖥️ **was02** — 로컬 저장소가 아직 등록되지 않았고 `highavailability`도 꺼져 있어서, §4-6의 'was01 / db01에서 로컬 저장소 등록' 블록과 같은 내용을 먼저 실행해야 합니다:
```bash
sudo tee /etc/yum.repos.d/local-web01.repo <<'EOF'
[local-web01]
name=Internal Repo via web01
baseurl=http://192.168.10.111/repo/rocky10/local
enabled=1
gpgcheck=0
EOF
sudo dnf config-manager --set-disabled baseos appstream extras
curl -I http://192.168.10.111/repo/rocky10/local/repodata/repomd.xml   # 200 OK
sudo dnf clean metadata
sudo dnf repolist                                                      # local-web01 만 보여야 함
sudo dnf install -y pacemaker corosync pcs resource-agents
```

🖥️ **web01** — `rpm -q`가 4줄 다 버전을 보여주면 이 블록은 **건너뜁니다**. `is not installed`가 나오면, web01은 자기 자신의 저장소를 등록하지 않으므로(§4-6 경고) `highavailability`를 이번 한 번만 지정해서 설치합니다:
```bash
sudo dnf install -y --enablerepo=highavailability pacemaker corosync pcs resource-agents
```

🖥️ 네 대 **모두**에서 마지막 확인:
```bash
rpm -q pacemaker corosync pcs resource-agents   # 4줄 모두 버전이 나와야 함 (corosync는 3.1.10-1.el10_2.x)
```

> 재현 기록(2026-10-01): 네 대 모두 110개 패키지(다운로드 27 MB, 설치 95 MB)가 설치됐고, 마지막 `rpm -q`에서 `pacemaker-3.0.1-5.el10_2.1`, `corosync-3.1.10-1.el10_2.2`, `pcs-0.12.2-3.el10_2.1`이 네 대 같았습니다. was02는 `dnf repolist`가 `baseos`/`appstream`/`extras`만 보여서 위처럼 로컬 저장소를 먼저 등록해야 했고(등록 뒤 `repolist`는 `local-web01` 하나), web01은 `rpm -q`가 네 개 모두 `is not installed`라서 `--enablerepo=highavailability`로 설치했습니다. 또 §9-3 앞부분의 'web01엔 이미 설치돼 있다'는 처음 가이드를 만들 때의 기록이고, 새로 만든 web01에는 해당하지 않았습니다.
>
> `resource-agents`만 노드마다 빌드가 달랐습니다 — 외부 저장소에서 설치한 web01·web02는 `4.16.0-53.el10_2.17`, 3)에서 받아 채운 로컬 저장소로 설치한 was01·was02는 `4.16.0-53.el10_2.9`였습니다. 3)에서 받은 뒤 `highavailability` 저장소에 새 빌드가 올라온 것으로 보이지만 확인하지는 않았습니다(**미확인**). web-cluster와 was-cluster는 서로 다른 클러스터이고 각 클러스터 안의 두 노드는 같으므로 지금은 문제가 없습니다. 같은 클러스터의 두 노드를 서로 다른 경로로 설치하면 이런 차이가 생길 수 있으니 `rpm -q`로 비교해 보세요.

**(쉬어 가기) 여기서 VM을 끄고 PC를 재부팅해야 할 때**

PC를 바로 재부팅하거나 VirtualBox 창을 닫지 말고, 먼저 VM을 정상 종료합니다. `vagrant halt`가 각 VM에 종료 신호를 보내 OS가 서비스와 디스크를 정리하며 꺼지게 하므로, VM 안에서 `poweroff`를 따로 칠 필요는 없습니다.

🖥️ 호스트 PC(PowerShell)에서:
```powershell
cd <프로젝트 폴더>\vagrant\3t     # Vagrantfile이 있는 폴더에서 해야 합니다
vagrant status                    # 지금 켜져 있는 VM 확인
vagrant halt                      # 이 폴더의 VM 전부 종료 (한 대만: vagrant halt web02)
vagrant status                    # 전부 poweroff 가 될 때까지 확인
```
전부 `poweroff`가 보이면 PC를 재부팅해도 됩니다. 다시 시작할 때는 같은 폴더에서 `vagrant up`(전부) 또는 `vagrant up web01 was01 web02 was02`처럼 필요한 VM만 올립니다. 부팅 뒤에는 §3-7의 확인(서비스망 양방향 ping)으로 bond0가 올라왔는지 봅니다. 이 시점에는 클러스터를 아직 시작하지 않았으므로(§9-6 전) 따로 정리할 것이 없습니다. 쉬기 전에 되돌릴 지점을 남기고 싶다면 `vagrant halt` 뒤에 `vagrant snapshot save web01 pkgs-done`처럼 VM마다 저장해 둘 수 있습니다(선택, 복원은 이 프로젝트에서 검증하지 않았습니다).

### 9-4. hacluster 계정 비밀번호 + pcsd 서비스 활성화

`pcs host auth`는 각 노드의 `hacluster` 시스템 계정으로 인증합니다. 기본적으로 비밀번호가 잠겨 있어 먼저 설정해야 합니다.

🖥️ web01, was01, web02, was02 **네 대 전부**에서:
```bash
sudo passwd hacluster
```
> ⚠️ **이 가이드에서는 4대 모두 비밀번호를 `<HACLUSTER_PASSWORD>`으로 통일해서 사용합니다.** 실습 환경 기준이며, 실제 운영 환경이라면 이렇게 쓰면 안 됩니다. `BAD PASSWORD: …` 경고(예: `The password contains the user name in some form`, 사전 단어 기반, 너무 짧음)는 root 권한으로 강제 설정하는 것이라 무시하고 진행해도 됩니다.

> **`<HACLUSTER_PASSWORD>`는 '여기에 본인이 정한 비밀번호를 넣으라'는 자리표시자입니다.** 꺾쇠 `<` `>`까지 그대로 치면 안 됩니다. bash에서 `<`는 입력 리다이렉션이라, `-p <HACLUSTER_PASSWORD>`를 그대로 붙여넣으면 `HACLUSTER_PASSWORD: No such file or directory` 오류가 나고 명령이 실행되지 않습니다.
>
> 실습용이면 `<HACLUSTER_PASSWORD>`처럼 간단한 영문 소문자 비밀번호 하나를 정해 `passwd`에서 4대에 똑같이 입력하고, 아래 9-6의 `pcs host auth -p …`에도 같은 값을 괄호 없이 씁니다(예: `-p <HACLUSTER_PASSWORD>`). `$`, `!`, `&`, 공백 같은 특수문자가 들어가면 셸이 해석하므로 `-p 'abc!123'`처럼 작은따옴표로 감싸야 합니다. 이 비밀번호는 노드 인증(`pcs host auth`) 때 쓰이고 그 뒤로는 인증 토큰으로 통신합니다. `<REPLICATION_PASSWORD>`(DB 복제 챕터)도 같은 방식으로 값을 정해 넣으면 되고, 포트폴리오로 공개할 가이드에는 실제 값을 적지 말고 자리표시자를 그대로 두세요.

```bash
sudo systemctl enable --now pcsd
sudo systemctl status pcsd --no-pager   # active (running) 확인
```
> `enable --now pcsd`는 응답이 없는 것처럼 약 19~25초 걸립니다(재현 기록 4대 모두 `Starting`→`Started`가 19~25초 간격). 멈춘 것이 아니니 기다리세요. `status`의 `Memory`가 약 500 MB로 보이는 것도 이 PC에서는 정상이었습니다. 90초가 넘어 `Result: timeout`이 나면 메모리 문제일 수 있으니 §16-3의 해당 증상을 참고하세요.

### 9-5. 방화벽 — 클러스터 통신 포트 개방

pcsd(2224/tcp)와 corosync 통신 포트가 기본적으로 막혀 있어 `pcs host auth`, `pcs cluster` 명령이 전부 실패합니다.

🖥️ web01, was01, web02, was02 **네 대 전부**에서:
```bash
sudo firewall-cmd --add-service=high-availability --permanent
sudo firewall-cmd --reload
```
> `high-availability`는 firewalld에 미리 정의된 서비스 묶음으로, pcsd·corosync가 쓰는 포트를 한 번에 열어줍니다.

### 9-6. pcs 클러스터 구성

**1) 노드 인증**

`pcs host auth`에 호스트 이름(`web02` 등)을 그대로 쓰면 DNS/`/etc/hosts`가 없어 실패합니다(`Could not resolve host`). `addr=`로 관리망 IP를 직접 지정해 우회합니다.

🖥️ web01에서:
```bash
sudo pcs host auth web01 addr=192.168.10.111 web02 addr=192.168.10.121 \
  -u hacluster -p <HACLUSTER_PASSWORD>
```

🖥️ was01에서:
```bash
sudo pcs host auth was01 addr=192.168.10.112 was02 addr=192.168.10.122 \
  -u hacluster -p <HACLUSTER_PASSWORD>
```
둘 다 `web01: Authorized` / `web02: Authorized`(was 쪽도 동일)가 떠야 합니다.

**2) 클러스터 생성** — 여기서부터 `addr=`는 **서비스망(bond0) IP**로 바뀝니다(관리망 IP가 아닙니다):

🖥️ web01에서:
```bash
sudo pcs cluster setup web-cluster web01 addr=10.10.10.11 web02 addr=10.10.10.21
```

🖥️ was01에서:
```bash
sudo pcs cluster setup was-cluster was01 addr=10.10.10.12 was02 addr=10.10.10.22
```

**3) 클러스터 기동**

🖥️ web01에서:
```bash
sudo pcs cluster start --all
sudo pcs cluster enable --all
```
🖥️ was01에서:
```bash
sudo pcs cluster start --all
sudo pcs cluster enable --all
```
> 기동 직후 몇 초는 pacemaker가 아직 준비 중일 수 있습니다. 바로 아래 4)에서 `Error: unable to get cib`가 나오면 10초쯤 뒤에 다시 실행하세요.

**4) STONITH 비활성화 (실습 환경 한정) — 반드시 3) 기동 *뒤에*, 그리고 빠뜨리지 마세요**

`pcs status` 위쪽에 `error: Resource start-up disabled since no STONITH resources have been defined`, `Configuration invalid (with errors)` 같은 줄이 뜨는 것은 실제 펜싱 장치(원격 전원 차단)가 없는 랩 환경인데 `stonith-enabled`가 아직 `true`라서입니다. **끄지 않으면 리소스가 기동을 거부합니다** — §10-1에서 VIP를 만들어도 `Started`가 아니라 `Stopped`로 남습니다.

🖥️ web01에서:
```bash
sudo pcs property set stonith-enabled=false
```
🖥️ was01에서:
```bash
sudo pcs property set stonith-enabled=false
```

적용됐는지 확인합니다(web01, was01 각각):
```bash
sudo pcs property config | grep -i stonith    # stonith-enabled 가 false 여야 함 (출력 모양은 pcs 버전에 따라 = 또는 : 로 다를 수 있음)
```

> ⚠️ **v16 정정 — 순서와 재현 기록**: 이전 가이드는 이 단계를 클러스터 기동보다 먼저 두었습니다. 기동 전에 실행하면 `Error: unable to get cib`가 나고(CIB는 pacemaker가 떠 있어야 접근할 수 있습니다. 재현 기록 web01·was01 모두), 이 오류를 넘기고 기동만 한 채 다시 실행하지 않으면 STONITH가 켜진 채로 남습니다. 재현 기록(2026-10-02)에서는 그 상태로 §10-1까지 진행해 `web_vip`가 `Stopped`로 남았습니다(체크리스트 72·73번).

**5) 확인**

🖥️ web01 또는 web02 아무 데서나:
```bash
sudo pcs status
```
`Node List`에 두 노드 다 `Online`으로 뜨고, `Current DC`에 실제 노드 이름이 들어가 있으면(`NONE`이 아니면) 성공입니다. 4)까지 마쳤다면 위쪽 `WARNINGS` 블록(STONITH `error:` 줄)이 없어야 합니다. was-cluster도 was01/was02 아무 데서나 동일하게 확인하세요.

> 재현 기록(2026-10-02, STONITH를 끄기 **전**): `Online: [ web01 web02 ]`, `Current DC: web01 … partition with quorum`, `0 resource instances configured`, `corosync`/`pacemaker`/`pcsd` 모두 `active/enabled`였고, `WARNINGS`에는 STONITH 관련 3줄 외에 `error: CIB did not pass schema validation`과 `Configuration invalid (with errors)`가 함께 있었습니다. `CIB did not pass schema validation`은 이전 기록에 없던 줄입니다.
>
> **끈 뒤 (확인됨, 2026-10-02)**: `sudo pcs property set stonith-enabled=false`는 `Warning: Setting property stonith-enabled to false leaves the cluster with no enabled means to fence nodes, resulting in the cluster not being able to recover from certain failure conditions`를 출력합니다 — 펜싱 장치가 없는 랩에서 일부러 끈 것이므로 정상입니다. `pcs property config | grep -i stonith`는 `stonith-enabled=false`였고, 약 20초 뒤 `pcs status`에서 `WARNINGS` 블록(STONITH `error:` 줄, `CIB did not pass schema validation`, `Configuration invalid (with errors)`)이 **전부 사라지고** `web_vip`(was-cluster는 `was_vip`)가 `Started`가 되어 있었습니다. 즉 CIB 경고도 STONITH를 끄면 함께 사라졌습니다(그 경고가 정확히 무엇 때문이었는지는 모르지만 `crm_verify`까지 갈 필요는 없었습니다). 이미 만든 리소스는 지우고 다시 만들지 않아도 됐습니다.

### 9-7. /etc/hosts 보완 (권장)

앞선 `pcs host auth`는 `addr=`로 이름 해석 문제를 우회했지만, 앞으로 `ssh web02`처럼 이름으로 접근하거나 다른 도구를 쓸 때를 대비해 등록해두는 걸 권장합니다.

🖥️ web01, was01, web02, was02, (선택) db01까지 다섯 대 전부에서:
```bash
sudo tee -a /etc/hosts <<'EOF'
192.168.10.121 web02
192.168.10.122 was02
EOF
```
(§3-2에서 이미 web01/was01/db01은 등록돼 있으니, 이번엔 web02/was02 두 줄만 추가하면 됩니다.)

(v16 r20) 두 번 실행하면 같은 두 줄이 중복으로 들어갑니다 — 재현 기록에서는 재부팅 전후로 두 번 실행해 web01·was01·web02·was02 모두 두 줄씩 중복이었고 동작에는 지장이 없었습니다. 실행 전에 `grep -c '^192.168.10.121 web02' /etc/hosts`가 `0`인지 확인하거나, 이미 중복이면 `sudo vi /etc/hosts`로 한 줄씩 지우세요.

### 9-8. 최종 확인 체크리스트

| 확인 항목 | 명령어 | 정상 기준 |
|---|---|---|
| bond0 노드 간 통신 | `ip route get <상대 IP>` (→ `dev bond0`) 후 `ping -c 3 <상대 서비스망 IP>` | 4개 방향 전부 0% loss, `local ... dev lo`가 아님, `ip neigh`가 `FAILED`가 아님 |
| 로컬 저장소 | `curl -I http://192.168.10.111/repo/rocky10/local/repodata/repomd.xml` | 200 OK |
| pcsd 데몬 | `systemctl status pcsd` | active (running), 4대 전부 |
| 클러스터 상태 | `sudo pcs status` | web01/web02, was01/was02 각각 Online 2개, DC가 NONE이 아님 |
| STONITH 해제 | `sudo pcs property config \| grep -i stonith` (web01, was01 각각) | `stonith-enabled`가 `false`, `pcs status` 위쪽에 STONITH `error:` 줄이 없음 |

### 9-9. 앞으로의 흐름 (요약)

| 서버 | 관리망 IP | bond0(서비스망) IP | 역할 |
|---|---|---|---|
| web01 | 192.168.10.111 | 10.10.10.11 | web-cluster 노드 1 |
| web02 | 192.168.10.121 | 10.10.10.21 | web-cluster 노드 2 |
| was01 | 192.168.10.112 | 10.10.10.12 | was-cluster 노드 1 |
| was02 | 192.168.10.122 | 10.10.10.22 | was-cluster 노드 2 |
| (예정) web VIP | — | **10.10.10.14** | web-cluster 플로팅 IP (아직 미등록) |
| (예정) was VIP | — | **10.10.10.15** | was-cluster 플로팅 IP (아직 미등록) |

여기까지가 §9의 전체 범위입니다 — web02/was02 부팅, bond0 구성, 클러스터 패키지 설치, pcs 클러스터 생성/기동까지 전부 완료된 상태입니다. 다음으로 이어질 작업(§10 예정):

1. VIP 리소스 등록 (`ocf:heartbeat:IPaddr2`, web-cluster는 10.10.10.14, was-cluster는 10.10.10.15)
2. httpd/tomcat을 pacemaker가 관리하는 리소스로 전환(`systemd:httpd`, `systemd:tomcat`), 액티브 노드에서만 뜨도록 제약(co-location) 설정
3. 페일오버 테스트(액티브 노드를 `pcs cluster stop`으로 내려서 VIP·서비스가 다른 노드로 넘어가는지 확인)

이 3가지는 실제 로그를 보면서 하나씩 진행하는 게 지금까지처럼 오류 없이 가는 데 더 안전합니다 — 준비되시면 말씀해주세요.

---

## 10. httpd/tomcat 이중화 완성 — VIP 등록, pacemaker 리소스 전환, 페일오버 테스트

§9에서 web-cluster/was-cluster가 둘 다 `Online` 상태까지는 됐지만, 아직 껍데기뿐인 클러스터입니다. 이 챕터에서 실제 서비스(httpd/tomcat)를 클러스터에 편입시키고, 노드 하나를 강제로 죽여도 서비스가 안 끊기는 것까지 직접 증명합니다.

> **이 챕터를 보는 법**: §9와 마찬가지로 모든 명령 블록 위에 🖥️ 로 실행 서버를 표시했습니다. 특히 이 챕터는 web01(기존 설정 수정)과 web02(신규 설치)를 자주 오가니, 붙여넣기 전에 프롬프트를 한 번 더 확인하세요.

### 10-1. VIP(Virtual IP) 리소스 등록

🖥️ **web01**에서:
```bash
sudo pcs resource create web_vip ocf:heartbeat:IPaddr2 \
  ip=10.10.10.14 cidr_netmask=24 op monitor interval=10s
```

🖥️ **was01**에서:
```bash
sudo pcs resource create was_vip ocf:heartbeat:IPaddr2 \
  ip=10.10.10.15 cidr_netmask=24 op monitor interval=10s
```

**확인** (web01 또는 web02 아무 데서나):
```bash
sudo pcs status
```
`web_vip (ocf:heartbeat:IPaddr2): Started web01`처럼 `Started`로 뜨면 성공입니다. was-cluster도 was01/was02 아무 데서나 동일하게 확인하세요.

> `Started`가 아니라 `Stopped`로 남고 `pcs status` 위쪽에 STONITH `error:` 줄이 보인다면 §9-6 4)(`stonith-enabled=false`)를 빠뜨린 것입니다. web-cluster는 web01에서, was-cluster는 was01에서 `sudo pcs property set stonith-enabled=false`를 실행하고 `pcs status`를 다시 보세요. 리소스를 지우고 다시 만들 필요는 없습니다(설정이 바뀌면 Pacemaker가 다시 계산해 시작합니다. 재현 기록(2026-10-02): 설정 약 20초 뒤 `web_vip`/`was_vip`가 `Started`가 됐습니다). 이미 만든 뒤에 `pcs resource create …`를 다시 실행하면 `Error: 'web_vip' already exists`가 나오는데, 이미 있다는 뜻이라 정상입니다.

**물리적으로도 확인**:
```bash
ip -4 addr show bond0
```
`Started`로 뜬 그 노드에서 기존 기본 IP 옆에 VIP가 `secondary`로 추가로 잡혀 있어야 합니다.

### 10-2. web02/was02에 httpd/tomcat 설치 + AJP를 VIP 기준으로 재구성

이 시점까지 web02/was02엔 클러스터 패키지(pacemaker 등)만 있고, 정작 서비스(httpd/tomcat) 자체가 설치돼 있지 않았습니다(§9는 클러스터 뼈대만 만드는 챕터였습니다). 지금부터 web02/was02에 httpd/tomcat을 새로 깔고, **web01의 기존 설정도 VIP를 바라보도록 함께 고칩니다.**

#### 10-2-1. web02 — httpd 설치 + AJP 프록시(was_vip 타겟)

🖥️ **web02**에서:
```bash
sudo dnf install -y httpd mod_ssl

sudo tee /etc/httpd/conf.d/ajp-proxy.conf <<'EOF'
# was_vip(10.10.10.15:8009)로 AJP 프록시 — was01/was02 어느 쪽이 액티브든 동일하게 도달
<Location /app/>
    ProxyPass ajp://10.10.10.15:8009/app/
    ProxyPassReverse ajp://10.10.10.15:8009/app/
</Location>
EOF

sudo setsebool -P httpd_can_network_connect 1
sudo apachectl configtest
```
> ⚠️ **파일 쓸 때 `sudo cat > 파일 <<EOF`가 아니라 `sudo tee 파일 <<EOF`를 쓰세요.** `>` 리다이렉션은 `sudo`가 적용되기 전에 지금 로그인한 일반 계정 셸이 먼저 처리하기 때문에, `sudo`를 앞에 붙여도 파일을 여는 시도 자체는 여전히 일반 계정 권한으로 이뤄져 `Permission denied`가 납니다. `tee`는 그 프로세스 자체가 root로 실행되면서 파일을 쓰므로 문제없습니다.

**실제로 겪은 문제**: `mod_ssl`을 설치하면 기본 SSL 가상호스트 설정(`ssl.conf`)이 같이 깔리는데, 자체서명 인증서가 자동 생성되지 않아 `configtest`가 아래로 실패합니다.
```
SSLCertificateFile: file '/etc/pki/tls/certs/localhost.crt' does not exist or is empty
```
이 프로젝트는 처음부터 HTTPS를 쓰지 않으므로(전부 `http://`로 테스트), 인증서를 만드는 대신 SSL 가상호스트 자체를 꺼버리는 게 가장 간단합니다.
```bash
sudo mv /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/ssl.conf.disabled
sudo apachectl configtest    # 이번엔 Syntax OK
```

```bash
sudo systemctl enable --now httpd
sudo firewall-cmd --permanent --zone=public --add-service=http
sudo firewall-cmd --reload
```

#### 10-2-2. web01 — 기존 AJP 타겟을 was_vip로 수정

기존 §4-2 설정은 was01 고정 IP(10.10.10.12)를 직접 바라보고 있습니다. 이대로면 was가 페일오버돼도 web은 계속 죽은 was01만 찾게 되므로, VIP를 바라보도록 고쳐야 진짜 HA가 됩니다.

🖥️ **web01**에서:
```bash
sudo vi /etc/httpd/conf.d/ajp-proxy.conf
```
`10.10.10.12`로 되어있는 두 줄을 `10.10.10.15`로 바꿉니다(⚠️ `<Location>`·`ProxyPass`·`ProxyPassReverse`의 끝 슬래시는 그대로 두세요 — 체크리스트 47번). 맨 위 주석(`# was01(10.10.10.12:8009)으로 AJP 프록시`)도 `# was_vip(10.10.10.15:8009)로 AJP 프록시`로 고쳐 두면 나중에 헷갈리지 않습니다 — 재현 기록에서는 주석이 예전 그대로였고 동작에는 영향이 없었습니다:
```
<Location /app/>
    ProxyPass ajp://10.10.10.15:8009/app/
    ProxyPassReverse ajp://10.10.10.15:8009/app/
</Location>
```
```bash
sudo apachectl configtest
sudo systemctl restart httpd
curl http://localhost/app/db-check
```

**실제로 겪은 문제**: 위 curl이 `503 Service Unavailable`로 실패했습니다. `sudo tail -30 /var/log/httpd/error_log`로 확인하니:
```
(111)Connection refused: AH00957: AJP: attempt to connect to 10.10.10.15:8009 (10.10.10.15:8009) failed
```
was01의 bond0엔 `10.10.10.15`(VIP)가 분명히 `secondary`로 잘 잡혀 있는데도(§10-1에서 확인) 이런 에러가 나는 이유는, was01 Tomcat의 AJP Connector(§5-3)가 **처음부터 `address="10.10.10.12"`로 고정 바인딩**돼 있었기 때문입니다. 같은 서버라도 다른 로컬 IP(VIP)로 오는 연결은 그 커넥터가 안 받아줍니다.

§5-3에서 `address`를 고정한 이유는 관리망 등 다른 대역에서 AJP 포트에 못 들어오게 막기 위한 보안 조치였는데, 지금은 §10-2-3(아래)에서 **방화벽이 이미 web01/web02 소스 IP로 접근을 제한**하고 있으므로, Tomcat 자체는 모든 인터페이스에서 듣도록 풀어도 안전합니다.

🖥️ **was01**에서:
```bash
sudo vi /usr/share/tomcat/conf/server.xml
```
`address="10.10.10.12"`를 `address="0.0.0.0"`으로 변경:
```xml
<Connector protocol="AJP/1.3"
           address="0.0.0.0"
           port="8009"
           redirectPort="8443"
           secretRequired="false" />
```
```bash
grep -n 'address=' /usr/share/tomcat/conf/server.xml    # address="0.0.0.0" 이 보여야 함 — 철자 주의(address): 틀리면 출력이 없어서 통과한 것처럼 보입니다
sudo systemctl restart tomcat
ss -tnlp | grep 8009    # 0.0.0.0:8009 (또는 *:8009) 확인
```

🖥️ **web01**에서 재확인:
```bash
curl http://localhost/app/db-check
```
`DB 연결 성공: appdb`가 나오면 성공입니다.

#### 10-2-3. was01 + was02 — AJP 방화벽 규칙에 web02도 추가

기존 §5-5 방화벽은 web01(10.10.10.11)만 8009 접근을 허용합니다. web02도 액티브가 될 수 있으니 추가해야 합니다.

🖥️ **was01**에서 (web02 소스 추가):
```bash
sudo firewall-cmd --permanent --zone=public --add-rich-rule=\
'rule family="ipv4" source address="10.10.10.21/32" port protocol="tcp" port="8009" accept'
sudo firewall-cmd --reload
sudo firewall-cmd --list-rich-rules    # web01/web02 두 규칙 다 확인
```

🖥️ **was02**에서 (web01 + web02 둘 다 허용 — was02는 처음이라 두 규칙 다 새로 추가):
```bash
sudo firewall-cmd --permanent --zone=public --add-rich-rule=\
'rule family="ipv4" source address="10.10.10.11/32" port protocol="tcp" port="8009" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule=\
'rule family="ipv4" source address="10.10.10.21/32" port protocol="tcp" port="8009" accept'
sudo firewall-cmd --reload
```

#### 10-2-4. db01 — was02의 DB 접근 허용

was02가 앱을 띄우면 db01(10.10.10.13)에 직접 접속을 시도합니다. 기존 §6-11 방화벽/§6-7 `pg_hba.conf`는 was01(10.10.10.12)만 허용하고 있습니다.

🖥️ **db01**에서:
```bash
sudo vi /pgdata/data/pg_hba.conf
```
맨 아래에 한 줄 추가:
```
host    all       all   10.10.10.22/32   scram-sha-256
```
```bash
sudo systemctl restart postgresql

sudo firewall-cmd --permanent --zone=public --add-rich-rule=\
'rule family="ipv4" source address="10.10.10.22/32" port protocol="tcp" port="5432" accept'
sudo firewall-cmd --reload
```

#### 10-2-5. was02 — Java + Tomcat 설치 + AJP 커넥터

🖥️ **was02**에서:
```bash
sudo dnf install -y java-21-openjdk tomcat9 tomcat9-webapps tomcat9-admin-webapps
sudo vi /usr/share/tomcat/conf/server.xml
```
AJP Connector 블록을 찾아 추가/주석 해제하되, **처음부터 `address="0.0.0.0"`, `secretRequired="false"`를 반드시 같이** 넣습니다:
```xml
<Connector protocol="AJP/1.3"
           address="0.0.0.0"
           port="8009"
           redirectPort="8443"
           secretRequired="false" />
```
```bash
sudo systemctl enable --now tomcat
ss -tnlp | grep 8009
```

**실제로 겪은 문제**: `secretRequired="false"`를 빠뜨리고 저장했더니, `ss -tnlp`에 8080(HTTP)만 뜨고 8009(AJP)는 안 떴습니다. Rocky 패키지의 server.xml 기본 템플릿(주석 처리된 예시)엔 이 속성이 원래 없어서, 주석만 풀고 `address`만 바꾸면 이 속성이 빠지기 쉽습니다. Tomcat 9.0.31+ 는 Ghostcat(CVE-2020-1938) 대응으로 이 속성이 없으면 AJP 커넥터 자체를 조용히 초기화 거부합니다(로그에 관련 예외가 남지만 다른 배포 로그에 묻혀 놓치기 쉽습니다). was01과 완전히 동일한 Connector 블록으로 맞추면 해결됩니다.

#### 10-2-6. WAR 파일을 was01 → was02로 전달

🖥️ **was01**에서:
```bash
cd /var/lib/tomcat/webapps
sudo python3 -m http.server 8090 &
sudo firewall-cmd --add-port=8090/tcp
```
> ⚠️ 8080이 아니라 **8090**을 쓰세요. Tomcat 자신이 이미 8080(HTTP 커넥터)을 쓰고 있어서 8080으로 띄우면 `OSError: [Errno 98] Address already in use`가 납니다.

🖥️ **was02**에서:
```bash
cd /tmp
curl -O http://10.10.10.12:8090/app.war
```
> ⚠️ `wget`이 아니라 **`curl -O`**를 쓰세요. Rocky 최소 설치 이미지엔 `wget`이 기본 포함돼 있지 않습니다(`wget: command not found`).
```bash
ls -la app.war    # 파일 크기가 0보다 커야 정상
sudo mv app.war /var/lib/tomcat/webapps/
sudo restorecon -Rv /var/lib/tomcat/webapps/app.war
sudo systemctl restart tomcat
```

🖥️ **was01**에서 정리:
```bash
fg          # python3 -m http.server를 포그라운드로 가져온 뒤 Ctrl+C로 종료
sudo firewall-cmd --remove-port=8090/tcp
```

#### 10-2-7. 최종 확인

🖥️ **was02**에서:
```bash
curl http://localhost:8080/app/db-check
```
🖥️ **web02**에서:
```bash
curl http://localhost/app/db-check
```
둘 다 `DB 연결 성공: appdb`가 나와야 합니다(web02 → was_vip → was01까지 전체 경로 최종 검증).

### 10-3. httpd/tomcat을 pacemaker 리소스로 전환

지금까지는 httpd/tomcat이 그냥 평범한 systemd 서비스라, "프로세스만 죽고 노드는 살아있는" 상황엔 대응하지 못합니다. pacemaker가 직접 시작/중지/모니터링하도록 편입시킵니다.

**1) systemd 자동시작 끄기** (재부팅 시 자동시작만 끄는 것이며, 지금 떠있는 프로세스는 안 건드립니다)

🖥️ **web01, web02** 둘 다에서:
```bash
sudo systemctl disable httpd
```
🖥️ **was01, was02** 둘 다에서:
```bash
sudo systemctl disable tomcat
```

**2) pacemaker 리소스로 등록**

🖥️ **web01**에서:
```bash
sudo pcs resource create web_httpd systemd:httpd op monitor interval=10s
```
🖥️ **was01**에서:
```bash
sudo pcs resource create was_tomcat systemd:tomcat op monitor interval=10s
```

**3) VIP와 묶기 (콜로케이션 + 순서 제약)**

🖥️ **web01**에서:
```bash
sudo pcs constraint colocation add web_httpd with web_vip score=INFINITY
sudo pcs constraint order web_vip then web_httpd
```
🖥️ **was01**에서:
```bash
sudo pcs constraint colocation add was_tomcat with was_vip score=INFINITY
sudo pcs constraint order was_vip then was_tomcat
```
> 콜로케이션은 "httpd(또는 tomcat)는 반드시 VIP랑 같은 노드에 떠야 한다"는 규칙, 순서 제약은 "VIP가 먼저 뜨고 나서 그 위에 서비스를 띄운다"는 규칙입니다. 이 둘이 있어야 페일오버가 나도 VIP+서비스가 항상 같은 노드로 통째로 옮겨갑니다.

(v16 r20) 예전에는 `… INFINITY`처럼 점수를 값만 적었는데, 재현 기록(pcs 0.12.2)에서 `Deprecation Warning: Specifying score as a standalone value is deprecated and might be removed in a future release, use score=value instead`가 나왔습니다(제약은 만들어졌고 동작에도 문제가 없었습니다). 경고가 안내한 `score=INFINITY` 형태로 바꿨으며, 이 형태를 직접 실행해 본 것은 아닙니다(**미확인**). `constraint order`의 `Adding web_vip web_httpd (kind: Mandatory) (Options: first-action=start then-action=start)`는 정상 출력입니다.

**4) 확인**

🖥️ web01(또는 web02) 아무 데서나:
```bash
sudo pcs status
```
`web_vip`와 `web_httpd`가 **같은 노드**에 `Started`로 떠야 정상입니다. was-cluster도 `was_vip`+`was_tomcat` 기준으로 동일하게 확인하세요.

```bash
curl http://192.168.10.111/app/db-check
```
여전히 `DB 연결 성공: appdb`가 나오는지 마지막으로 확인합니다.

### 10-4. 페일오버 테스트

web-cluster의 액티브 노드(web01)를 강제로 내려서, VIP+httpd가 web02로 실제로 넘어가는지 직접 확인합니다.

🖥️ **web01**에서:
```bash
sudo pcs cluster stop web01
```

> ⚠️ **이 직후 web01 자신에서 `pcs status`나 `curl`을 돌리면 실패하는 게 정상입니다.** `Error: error running crm_mon, is pacemaker running? Connection refused`, `curl: (7) Failed to connect ... Could not connect to server` 둘 다 나옵니다 — 방금 그 노드의 pacemaker/corosync를 직접 껐으니, 그 노드는 클러스터 상태를 물어볼 대상 자체가 없어진 것뿐입니다. **확인은 반드시 살아있는 반대쪽 노드(web02)에서** 합니다.

🖥️ **web02**에서:
```bash
sudo pcs status
```
`web_vip`, `web_httpd` 둘 다 이번엔 **web02**에 `Started`로 떠있어야 성공입니다.
```bash
curl http://192.168.10.121/app/db-check
```
(`.121`은 web02 자신의 관리망 IP입니다.) `DB 연결 성공: appdb`가 나오면 페일오버 성공입니다.

was-cluster도 같은 방식으로 반복합니다.

🖥️ **was01**에서:
```bash
sudo pcs cluster stop was01
```
🖥️ **was02**에서:
```bash
sudo pcs status
```

**실제로 겪은 문제**: 이 시점에서 `was_vip`, `was_tomcat`이 was02로 안 넘어가고 계속 `Stopped`로 남아있었습니다. `pcs status` 출력 하단에 이런 기록이 있었습니다:
```
Failed Resource Actions:
  * was_vip 10s-interval monitor on was02 returned 'Not installed' at ... (훨씬 이전 시각)
```
이건 §10-3 이전, was02에 아직 뭔가 준비가 덜 됐던 시점에 남은 오래된 실패 기록입니다. Pacemaker는 이런 실패를 "이 노드에선 이 리소스를 절대 못 돌린다"는 뜻으로 받아들여서, **누가 지워주기 전까진 그 노드를 후보에서 영구 제외**합니다. 살아있는 노드(was02)에서 아래로 지워주면 됩니다.
```bash
sudo pcs resource cleanup was_vip
sudo pcs resource cleanup was_tomcat
sudo pcs status    # 몇 초 뒤 was_vip/was_tomcat이 was02에 Started로 재평가됨
```
재현 기록(2026-10-02)에서는 이 `cleanup`이 필요 없었습니다 — `pcs cluster stop was01` 뒤 첫 `pcs status`에서 이미 `Started was02`였고 `Failed Resource Actions` 줄도 없었습니다(해는 없음). 위 증상(`Stopped` + `Failed Resource Actions`)이 보일 때만 실행하세요.
```bash
curl http://localhost:8080/app/db-check
```
(v16 r20 정정) 예전 가이드는 여기에 `curl http://192.168.10.122/app/db-check`를 적었는데, was02에는 80번 포트를 듣는 프로세스가 없습니다(Tomcat은 8080, AJP는 8009이고 80번은 web의 Apache입니다). 재현 기록에서 그대로 실행하자 `curl: (7) Failed to connect to 192.168.10.122 port 80 after 0 ms: Could not connect to server`가 즉시 나왔고(`after 0 ms`는 기다리다 실패한 게 아니라 바로 거절됐다는 뜻) 여섯 번 반복해도 같았습니다. 기다릴 필요 없이 위처럼 `localhost:8080`으로 확인하면 `DB 연결 성공: appdb`가 나옵니다. 여기까지 확인되면, web02에서도 다시:
```bash
curl http://192.168.10.121/app/db-check
```
`DB 연결 성공: appdb`가 나와야 합니다(was_vip가 was02로 옮겨간 상태에서도 web 쪽 AJP 프록시가 정상적으로 도달하는지 최종 확인).

> 💡 **알아두면 좋은 설계 한계**: 지금 VIP(10.10.10.14/15)는 서비스망(내부 전용) 위에 있어서, 호스트 PC 등 외부에서 "항상 같은 주소로 접속했더니 알아서 살아있는 노드로 간다"는 진짜 외부 관점의 무중단은 지금 구조로는 확인할 수 없습니다(web01/web02 각자의 관리망 IP를 따로 쳐서 검증하는 방식입니다). 실제 운영이라면 로드밸런서나 외부에서 닿는 대역에도 VIP를 하나 더 둬야 진짜 무중단이 됩니다 — 지금 랩 환경에선 "리소스가 노드 간에 정상적으로 옮겨가는가"를 증명하는 것으로 충분하고, 이 부분은 추후 개선 과제로 남겨둡니다.

### 10-5. 원상복구

테스트가 끝났으면 내려둔 노드를 다시 살립니다. was 쪽은 리소스가 지금 자리(was02)에 그대로 있어도 동작엔 문제없습니다(active-backup 구조라 굳이 원래 노드로 되돌릴 필요는 없습니다). **web 쪽은 그렇지 않습니다 — 이 절 끝의 ⚠️를 먼저 보세요.**

🖥️ **web01**에서:
```bash
sudo pcs cluster start web01
```
🖥️ **was01**에서:
```bash
sudo pcs cluster start was01
```

확인:
```bash
sudo pcs status
```
`Online: [ web01 web02 ]`(was-cluster는 `[ was01 was02 ]`)로 두 노드 다 다시 뜨면 완료입니다. 재현 기록(2026-10-02): 시작 뒤에도 리소스는 `Started web02`/`Started was02`에 그대로 남았습니다(was는 정상).

**⚠️ web 리소스는 web01에 돌려놓고 다음 챕터로 가세요 (v16 r22, 실제로 겪음)**

web01의 Apache는 §4-6의 **로컬 저장소 서버를 겸합니다**(`http://192.168.10.111/repo/…`). §10-3에서 httpd를 Pacemaker가 관리하도록 `systemctl disable`했기 때문에, `web_httpd`가 web02에 있는 동안은 web01의 Apache가 꺼져 있고 저장소도 같이 멈춥니다. 재현 기록(2026-10-03): 이 상태에서 db02의 `sudo dnf install -y postgresql-server postgresql-contrib`가 아래처럼 실패했습니다(was02 설치 등 이전 단계가 통과한 것은 페일오버 테스트 전이었기 때문입니다).
```
Errors downloading metadata for repo 'local-web01':
  - Curl error (7): Could not connect to server for http://192.168.10.111/repo/rocky10/local/repodata/repomd.xml [Failed to connect to 192.168.10.111 port 80 after 1 ms: Could not connect to server]
Error: Failed to download metadata for repo 'local-web01': Cannot download repomd.xml: Cannot download repodata/repomd.xml: All mirrors were tried
```
`after 1 ms`는 기다리다 실패한 게 아니라 80번을 듣는 프로세스가 없어서 즉시 거절됐다는 뜻입니다(404와 다름 — 체크리스트 74·79번).

확인(🖥️ **web01**에서):
```bash
sudo pcs status | grep -E 'web_vip|web_httpd'    # Started web02 이면 이 상태
```
복구 — web 리소스를 web01로 되돌립니다(§10-4에서 쓴 방식의 반대 방향):

🖥️ **web02**에서:
```bash
sudo pcs cluster stop
```
🖥️ **web01**에서:
```bash
sudo pcs status | grep -E 'web_vip|web_httpd'                                  # Started web01 이어야 함
curl -sI http://192.168.10.111/repo/rocky10/local/repodata/repomd.xml | head -1    # HTTP/1.1 200 OK
```
🖥️ **web02**에서 (확인 뒤 클러스터 복귀):
```bash
sudo pcs cluster start
```
재현 기록(2026-10-03): 이 순서로 `web_vip`/`web_httpd`가 `Started web01`, 저장소가 `HTTP/1.1 200 OK`가 됐고, 이어서 db02의 PostgreSQL 설치가 `Complete!`였습니다. 원인도 확인했습니다(v16 r23): 복구 전 web01에서 `systemctl is-active httpd`가 `inactive`, `sudo pcs status | grep -E 'web_vip|web_httpd'`가 `web_vip`·`web_httpd` 둘 다 `Started web02`였습니다. `pcs cluster start` 뒤에도 리소스가 web01에 남았는지는 따로 확인하지 않아 **미확인**이었습니다. 이후 관찰(2026-10-05, v16 r24): 첫 복구 뒤 다른 작업을 하는 사이에 `Started web02`로 돌아가 있는 것이 한 번 확인됐고(원인 **미확인** — 가이드에 `resource-stickiness` 설정이 없다는 점만 알려진 사실), 같은 복구를 다시 하자 그 직후 확인에서는 `Started web01`이었습니다. 그 뒤에도 계속 web01에 남는지는 **미확인**이므로, 저장소가 필요한 작업 전에는 매번 `pcs status`와 `curl`로 확인하세요. 재확인(2026-10-05 09:40 UTC, §14 완료 뒤, v16 r25): `web_vip`, `web_httpd` 모두 `Started web01`, 노드는 web01·web02 모두 Online이었습니다(그 사이 구간에서 위치가 바뀌었는지는 확인하지 않음).

앞으로의 규칙: 챕터 11 이후(db02, witness01, PAF 설치 등) web01 저장소가 필요한 작업이 많으므로 **`web_httpd`를 web01에 둔 채 진행**하고, 클라이언트에서 `dnf install` 전에 위 `curl … | head -1`이 `200 OK`인지 확인하세요. 페일오버 테스트를 다시 했다면 이 복구를 반복합니다. 저장소를 Pacemaker 관리 밖으로 분리하거나 httpd를 clone으로 바꾸는 근본 해결은 **적용·검증하지 않았습니다**.

---

여기까지 **Phase 1 + Phase 2가 전부 완료**되었습니다 — 3계층 폐쇄망 인프라 구축부터 web/was 이중화, VIP 페일오버 테스트까지 실제 로그로 전부 검증됐습니다.


