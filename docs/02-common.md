> 이 문서는 `3tier-rocky10-guide-v16.md` 의 341~541줄을 옮겨 공개용으로 문장을 다듬은 것이다. 코드, 명령, 출력, 설정값은 원본 그대로이고, 비밀번호와 로컬 경로만 자리표시자로 바꿨다.

## 3. 공통 초기 설정 (web01 / was01 / db01 3대 모두 동일하게 적용)

```bash
vagrant ssh web01   # was01, db01도 각각 동일하게
sudo -i
```

> **팁**: 여러 서버 터미널 창을 동시에 열어놓고 작업하다 보면 다른 서버 프롬프트가 섞여서 복사되는 실수가 생기기 쉽다(예: db01 창에 `[root@was01 ~]#`가 그대로 붙어 `command not found`가 나는 경우). 명령어를 붙여넣기 전에 지금 어느 서버 창인지 한 번씩 확인한다.

### 3-1. 호스트명 확인

```bash
hostnamectl        # 'Static hostname:' 줄이 자기 이름(web01 / was01 / db01)이면 그대로 두세요
```

`Static hostname: (unset)`이거나 `localhost` 계열이면 **그 노드만** 설정한다:
```bash
hostnamectl set-hostname db01   # 자기 이름으로 (web01 / was01 / db01)
```

> **`vagrant up`이 끝까지 성공한 노드는 호스트명이 이미 맞다. 노드마다 다를 수 있다 (v16, 세 번째 재현에서 확인).** web01, was01은 첫 `hostnamectl`부터 `Static hostname: web01` / `was01`이었다. 반대로 db01은 `Static hostname: (unset)` / `Transient hostname: localhost`였다(db01은 부팅과 SSH 응답이 유난히 늦던 노드였고, 그 노드에서만 Vagrant의 후속 단계가 적용되지 않은 것으로 보인다. 정확한 원인은 **미확정**). 이미 맞는 노드에 `set-hostname`을 다시 실행해도 해는 없지만, 3대 모두 먼저 확인한다. **호스트명은 §3-3의 관리망 IP와 §3-5의 bond0 IP를 고르는 열쇠이므로 반드시 먼저 맞춰야 한다.**

### 3-2. /etc/hosts 설정

```bash
cat >> /etc/hosts <<'EOF'
192.168.10.111 web01
192.168.10.112 was01
192.168.10.113 db01
EOF
```

### 3-3. 관리망(private_network) 확인: 이미 잡혀 있으면 아무것도 하지 않는다

먼저 상태만 본다:
```bash
ip -4 -o addr show dev enp0s8
nmcli -f NAME,DEVICE con show
```
- `inet 192.168.10.11x/24`가 보이면(세 번째 재현의 web01, was01) Vagrant가 이미 설정한 것이다. **아래 블록을 실행할 필요가 없다.** 이때 프로파일 이름은 `mgmt-net`이 아니라 `enp0s8`이다(Vagrant가 만든 것).
- 아무것도 안 나오면(세 번째 재현의 db01) 아래 블록을 실행한다.

🖥️ 3대 모두 **똑같이** 붙여넣어도 된다. IP는 호스트명(§3-1)으로 자동 결정되고, 이미 IP가 있으면 스스로 건너뛴다:
```bash
HN=$(hostname -s)
case "$HN" in
  web01)     MGMT_IP="192.168.10.111" ;;
  was01)     MGMT_IP="192.168.10.112" ;;
  db01)      MGMT_IP="192.168.10.113" ;;
  web02)     MGMT_IP="192.168.10.121" ;;
  was02)     MGMT_IP="192.168.10.122" ;;
  db02)      MGMT_IP="192.168.10.114" ;;
  witness01) MGMT_IP="192.168.10.115" ;;
  *)         MGMT_IP="" ;;
esac

if [ -z "$MGMT_IP" ]; then
  echo "❌ 호스트명($HN)이 목록에 없습니다 → §3-1의 hostnamectl set-hostname부터 하세요."
elif ip -4 -o addr show dev enp0s8 | grep -q " ${MGMT_IP}/24 "; then
  echo "✅ 관리망(enp0s8)에 이미 ${MGMT_IP}/24 가 있습니다 — 건너뜁니다."
else
  echo "▶ $HN 관리망 IP = ${MGMT_IP}/24 설정"
  nmcli -g NAME con show | grep -qx mgmt-net || nmcli con add type ethernet ifname enp0s8 con-name mgmt-net ipv4.method manual ipv4.addresses "${MGMT_IP}/24"
  nmcli con mod mgmt-net ipv4.method manual ipv4.addresses "${MGMT_IP}/24"
  nmcli con up mgmt-net
fi
```
> 세 번째 재현에서 web01, was01은 Vagrant가 이미 `enp0s8`에 IP를 넣어 둔 상태였는데 이 절의 예전 명령(`nmcli con add ... mgmt-net`)을 그대로 실행해서, 같은 NIC에 프로파일이 둘(`enp0s8` = DEVICE `--`, `mgmt-net`) 생겼다(같은 IP라 동작에는 지장이 없었다). 이미 그렇게 됐다면 정리는 선택이다: `nmcli -f NAME,DEVICE con show`에서 `enp0s8`의 **DEVICE가 `--`(어디에도 안 물림)일 때만** `nmcli con delete enp0s8`. DEVICE가 `enp0s8`이면 지금 쓰는 프로파일이니 지우지 않는다(관리망 IP가 사라진다. `vagrant ssh`는 NAT(`enp0s3`)로 들어오므로 접속은 유지되지만 192.168.10.x 통신이 끊긴다).

### 3-4. dnf 업데이트 및 기본 도구 설치

```bash
dnf update -y
dnf install -y chrony vim tar curl wget bind-utils net-tools policycoreutils-python-utils unzip tcpdump
```
> `tcpdump`(v16 추가)는 서비스망 통신 문제(ARP 요청이 오가는지 등)를 진단할 때 쓴다. 폐쇄망으로 전환된 뒤에는 설치하려면 `baseos/appstream`을 잠깐 켜야 하므로(§9 web02 기록), 인터넷이 되는 이 시점에 미리 넣어둔다.
> `unzip`은 나중에 war 파일 내용물을 확인할 때 쓴다(Rocky 최소 설치엔 기본으로 없다). 이 시점엔 아직 인터넷 저장소를 쓸 수 있어서 바로 설치되지만, §4-6 이후(로컬 저장소로 전환한 뒤) 뒤늦게 필요해지면 `jar tf <war파일>`로 대신할 수 있다(JDK에 포함).

### 3-5. 서비스망 bond0 구성 (nmcli)

먼저 실제 인터페이스 이름 확인:
```bash
nmcli device status
# 관리망(enp0s8)을 제외한 나머지 2개(대개 enp0s9, enp0s10)가 서비스망용 NIC
```

**자동 생성된 DHCP 대기 프로파일 정리 (필요할 때만)**: intnet(svc-net)에는 DHCP 서버가 없는데도, NetworkManager가 서비스망 NIC에 `Wired connection N` 프로파일을 자동으로 만들어 DHCP를 기다릴 수 있다. `nmcli device status`에서 서비스망 NIC(enp0s9/enp0s10)이 `connecting (getting IP configuration)`로 멈춰 있을 때만 정리하면 된다. **지우기 전에 어떤 프로파일이 어떤 NIC에 물려 있는지 먼저 본다:**
```bash
nmcli -f NAME,DEVICE,UUID con show
```
> ⚠️ **`enp0s3`(NAT, `vagrant ssh`가 들어오는 길)나 `enp0s8`(관리망)에 물린 프로파일은 절대 지우지 않는다.** 지우는 순간 그 NIC의 IP가 사라져 SSH/콘솔이 멈춘다. `Wired connection N`의 번호는 VM마다, 부팅마다 달라서, 예시 이름을 그대로 복사하지 말고 반드시 위 표의 `DEVICE` 열을 보고 고른다(실제로 web01 Phase 1 기록에서 NAT NIC의 프로파일이 `Wired connection 2`였다. 이름만 보고 지우다 세션이 멈춘 사례가 있으나 어떤 프로파일이었는지는 기록으로 확정하지 못했다. 체크리스트 49번).

지울 대상은 `DEVICE`가 `enp0s9` / `enp0s10` / `--`(어디에도 안 물림)인 `Wired connection N`뿐이다:
```bash
nmcli con delete "Wired connection 1" "Wired connection 4"   # ← 위 표에서 고른 '실제 이름'으로 교체
```

**bond0 생성: 3대(web01 / was01 / db01)가 모두 똑같은 블록을 붙여넣는다.** (v16: 서버마다 IP를 손으로 바꾸던 방식이 was01, db01에서 계속 사고를 냈다. 이제 IP는 **호스트명**으로 자동 결정되므로 고칠 곳이 없다. 이미 있는 프로파일은 다시 만들지 않으니 몇 번 실행해도 안전하다. 서비스망 NIC 이름이 `enp0s9`/`enp0s10`이 아니라면 위 `nmcli device status`의 실제 이름으로 블록 안의 두 줄만 바꾼다.)

🖥️ web01, was01, db01 **각각에서** (`sudo -i`로 root가 된 상태, 호스트명이 §3-1대로 맞아야 함):
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

**서버별 IP 값 (블록이 자동으로 고르는 값, 검증용 표)**
| 서버 | bond0 IP |
|---|---|
| web01 | 10.10.10.11/24 |
| was01 | 10.10.10.12/24 |
| db01  | 10.10.10.13/24 **및** 10.10.10.23/24 (예약 IP, 나중에 db_vip가 됨) |

(web02/was02/db02/witness01의 값도 같은 블록에 들어 있다. 전체 주소는 §0 정리표를 본다.)

확인: 마지막에 `✅`가 나와야 한다.
```bash
GOT=$(ip -4 -o addr show bond0 | awk '{print $4}' | sort | paste -sd,)
WANT=$(echo "$BOND_IPS" | tr ',' '\n' | sort | paste -sd,)
[ "$GOT" = "$WANT" ] && echo "✅ bond0 IP 일치: $GOT" || echo "❌ 불일치 — 현재 [$GOT] / 기대 [$WANT]  → 위 블록을 그대로 다시 실행하세요"
grep -E 'Bonding Mode|Currently Active Slave|Slave Interface|MII Status' /proc/net/bonding/bond0
```
> `bond0`은 systemd 서비스가 아니라 네트워크 인터페이스 이름이다. `systemctl status bond0`은 `Unit bond0.service could not be found`만 나오니, 상태 확인은 항상 `cat /proc/net/bonding/bond0`을 쓴다. 정상이면 `Bonding Mode: fault-tolerance (active-backup)`, 슬레이브 2개(`enp0s9`, `enp0s10`) 모두 `MII Status: up`이다.

> ℹ️ **`nmcli con up`에서 에러가 떠도, 판정 기준은 에러 메시지가 아니라 위 확인 블록의 `✅`와 슬레이브 2개 `MII Status: up`이다 (v16, 실제 재현. 재현할 때마다 문구가 달랐다).** ① 이전 재현(위 "v16 업데이트" 3번): Phase 1의 web01, was01, db01 3대 모두 첫 `bond0-port1`에서 `A dependency of the connection failed`가 났다(컨트롤러가 아직 안 올라온 상태에서 첫 슬레이브를 올려서 생기는 순서 문제로 보임). ② 세 번째 재현의 web01, was01: 에러가 **전혀 없었다**(이유는 미확정). ③ 세 번째 재현의 db01: `Connection '(null)' ((null)) successfully added.`(프로파일 이름이 `(null)`로 찍힘), 첫 `up bond0-port1`에서 `The base network connection was interrupted`, 마지막 재시도에서 `Unable to determine UID of the request`가 났지만 이어진 검증은 `✅ bond0 IP 일치: 10.10.10.13/24,10.10.10.23/24`, `Currently Active Slave: enp0s9`, 슬레이브 2개 `up`으로 **통과**했다. ③의 원인은 확정하지 못했다. `dnf update`로 NetworkManager, dbus-broker, systemd가 방금 바뀌었고 아직 재부팅 전이라는 점, 활성(`connecting`) 상태의 DHCP 대기 프로파일 3개를 막 지운 직후라는 점이 후보일 뿐이며, web01, was01도 같은 업데이트를 받았으므로 단정할 수 없다. **에러가 났던 노드는 §3-7의 재부팅 확인을 꼭 한다.** 참고로 `Currently Active Slave`가 `enp0s9`인지 `enp0s10`인지는 노드와 부팅마다 달랐다(세 번째 재현: web01, was01은 `enp0s10`, db01은 `enp0s9`). active-backup에서는 정상이며 어느 쪽이든 상관없다.

> ⚠️ **실제로 네 번 반복된 실수(원본 빌드의 was01, db01, 재현 때의 was01, db01): 다른 서버 창에서 복사한 IP 그대로 실행.** 그 결과 두 서버가 같은 IP를 쓰거나(충돌), 정작 자기 IP가 없어 PostgreSQL이 `could not bind IPv4 address "10.10.10.13": Cannot assign requested address`로 죽는 연쇄 문제로 이어졌다. 위 블록은 이 실수를 구조적으로 막기 위한 것이지만, 옛 방식(IP를 직접 입력)으로 이미 만들었다면 아래로 바로잡는다.
> - **IP가 틀린 경우**: 위 블록을 **그대로 다시 실행**하면 된다(IP만 덮어쓰고 프로파일은 재사용). `nmcli con add`부터 손으로 다시 치지 않는다. `Warning: There is another connection with the name 'bond0-port1'` 중복 프로파일이 생긴다(재현 때 was01, db01에서 실제로 생겼음).
> - **이미 중복 프로파일이 생긴 경우**: `nmcli -f NAME,UUID,DEVICE con show`에서 같은 이름이 두 개면 `DEVICE`가 `--`인 쪽을 `nmcli con delete uuid <UUID>`로 지운다.
> - **web01/was01에 옛 방식으로 `.21`/`.22`(세컨더리)까지 붙여버린 경우**: 위 블록을 다시 실행하면 `nmcli con up bond0`이 주소를 통째로 다시 적용해 세컨더리도 정리된다(재현 때 was01, db01에서 `nmcli con mod` + `nmcli con up bond0` 뒤에 주소가 `.11/.21` → `.12/.22`, `.11/.21` → `.13/.23`으로 통째로 교체된 것이 확인됨). bond0를 재활성화하지 않고 세컨더리만 무중단으로 떼어내려면 §9-2 0)의 `ip addr del` 방식을 쓴다.

### 3-6. firewalld / SELinux 기본 상태 확인

```bash
systemctl status firewalld --no-pager
getenforce   # Enforcing이어야 정상
```

### 3-7. 재부팅 후 확인 (권장, 특히 §3-5에서 에러가 났던 노드) (v16 신설)

§3-4의 `dnf update`는 새 커널(세 번째 재현: `kernel-core-6.12.0-211.60.1.el10_2`)과 systemd, NetworkManager, dbus-broker를 바꿨지만 재부팅하지 않았으므로 **아직 이전 커널로 실행 중**이다(`hostnamectl`의 `Kernel:` 줄이 `6.12.0-211.16.1…`이었다). 지금 한 번 재부팅해 두면 (1) 새 커널로 올라오고, (2) bond0과 관리망 IP가 **부팅 때 자동으로 올라오는지**(NetworkManager 프로파일이 영구 저장됐는지)를 이른 시점에 확인할 수 있다. 이 확인을 건너뛰면 같은 문제가 §9, §11, §16에서 '네트워크 탓인가 DB 탓인가'라는 형태로 뒤늦게 드러날 수 있다.

🖥️ 각 노드에서 (Vagrant 명령이 아니라 **VM 안에서** 실행):
```bash
reboot
```
VirtualBox 콘솔에 `<이름> login:` 프롬프트가 뜬 뒤 PowerShell에서 `vagrant ssh <이름>` → `sudo -i` 후 확인한다.

> ℹ️ **재부팅 직후에는 `vagrant ssh`가 아무 메시지 없이 그냥 프롬프트로 돌아올 수 있다 (v16, 세 번째 재현의 세 노드 모두).** Vagrant가 ssh 오류 메시지를 숨기기 때문에 그렇게 보이는 것이고, 이 PC에서는 콘솔에 로그인 프롬프트가 뜬 뒤에도 접속이 되기까지 시간이 걸렸다(bond0도 부팅 후 약 2분(123~138초)에야 붙었다). 먼저 기다려 보고, 실제 오류를 보려면 `vagrant ssh web01 -- -v`(뒤의 `-v`가 ssh 상세 로그를 켠다)를 쓴다. 오래 안 되면 VirtualBox 콘솔에서 `vagrant`로 로그인해(비밀번호는 보통 `vagrant`) `ip -4 -br addr show enp0s3`(→ `10.0.2.15/24`), `systemctl is-active sshd`(→ `active`), `ss -tlnp | grep ':22 '`(→ 22번 LISTEN)를 확인한다. 세 번째 재현에서는 세 노드 모두 이 셋이 정상이었으므로 '기다리면 되는' 경우였다. 왜 그렇게 오래 걸렸는지는 **미확정**이다(CPU를 나눠 쓰는 VM 3대가 동시에 부팅하면서 느려졌을 가능성, 추정).

확인 명령:
```bash
uname -r                                        # §3-4에서 'Installed: kernel-core-…'로 나온 버전과 같아야 함
hostname -s                                     # 자기 이름
ip -4 -o addr show enp0s8 | awk '{print $4}'    # 관리망: 192.168.10.111(web01) / .112(was01) / .113(db01)
ip -4 -o addr show bond0  | awk '{print $4}'    # web01 10.10.10.11/24 · was01 10.10.10.12/24 · db01 10.10.10.13/24 와 10.10.10.23/24(두 줄)
grep -E 'Currently Active Slave|Slave Interface|MII Status' /proc/net/bonding/bond0    # 슬레이브 2개 모두 up
nmcli con show --active                         # bond0 · bond0-port1 · bond0-port2 · 관리망 프로파일 1개(enp0s8 또는 mgmt-net) · NAT(Wired connection N, enp0s3)
```

세 대가 모두 다시 올라온 뒤 **양방향**으로 한 번씩 통신을 확인한다(한 방향만 실패하는 증상이 이 프로젝트에서 가장 오래 걸린 문제였다. §8 43번):
```bash
# web01에서
ping -c 2 10.10.10.12 && ping -c 2 10.10.10.13 && ping -c 2 10.10.10.23
# db01에서
ping -c 2 10.10.10.11 && ping -c 2 10.10.10.12
```
응답 시간이 `0.0x ms`~`0.1 ms`대로 비정상적으로 빠르면 상대가 아니라 **내 주소**에 ping한 것일 수 있다(`ip route get <IP>`가 `local … dev lo`로 나오면 내 주소).

(선택) 여기가 **'공통작업 완료'** 지점이다. 이후 실수를 되돌리기 쉽도록 PowerShell에서 `vagrant snapshot save web01 common-done` (was01, db01도 각각)을 해 두면 편하다. 이 프로젝트에서 `restore`까지 검증하지는 않았으니, 복구한 뒤에는 위 확인 명령으로 IP부터 다시 확인한다.

여기까지가 3대 공통 작업이다. 이제부터 서버 역할별로 나눠 진행한다.

---

