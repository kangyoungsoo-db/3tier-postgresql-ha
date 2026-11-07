> 이 문서는 `3tier-rocky10-guide-v16.md` 의 542~1624줄을 옮겨 공개용으로 문장을 다듬은 것이다. 코드, 명령, 출력, 설정값은 원본 그대로이고, 비밀번호와 로컬 경로만 자리표시자로 바꿨다.

## 4. web01: Presentation Tier 구축

### 4-1. Apache HTTPD 설치

```bash
dnf install -y httpd
systemctl enable --now httpd
```

### 4-2. mod_proxy_ajp로 was01 연동

```bash
grep -i proxy_ajp /etc/httpd/conf.modules.d/00-proxy.conf
# 출력이 'LoadModule proxy_ajp_module ...'로 시작하면(앞에 # 없음) 이미 활성입니다 — 편집할 것이 없습니다(web01 기록이 이 상태였습니다).
# '#LoadModule ...'처럼 # 이 붙어 있을 때만 vi로 열어서 # 을 지우세요.
```

```bash
cat > /etc/httpd/conf.d/ajp-proxy.conf <<'EOF'
# was01(10.10.10.12:8009)으로 AJP 프록시
<Location /app/>
    ProxyPass ajp://10.10.10.12:8009/app/
    ProxyPassReverse ajp://10.10.10.12:8009/app/
</Location>
EOF

apachectl configtest    # Syntax OK 확인
systemctl restart httpd
```

> `apachectl configtest`가 `Syntax OK` 앞에 `AH00558: Could not reliably determine the server's fully qualified domain name, using <이 서버의 IP>. Set the 'ServerName' directive globally to suppress this message`를 함께 찍는 것은 정상이다(web01 기록에서는 `using 192.168.10.111`이었다). 동작에 영향이 없고, 없애고 싶을 때만 `echo 'ServerName web01' > /etc/httpd/conf.d/servername.conf` 후 `systemctl reload httpd`를 한다(선택).

> ⚠️ **`<Location>`과 `ProxyPass`, `ProxyPassReverse`의 끝 슬래시(`/`)는 세 군데 모두 똑같아야 한다.** 위 블록은 전부 `/app/`(끝 슬래시 있음)이다. 다시 입력하다가 `<Location /app>`(없음)과 `.../app/`(있음)을 섞으면 요청이 `/app//db-check`로 바뀌어 `{"status":404,...,"path":"/app//db-check"}`가 나온다(web01 재현 기록). 이 응답은 Tomcat/앱 문제가 아니라 이 파일의 슬래시 불일치다. 셋을 전부 `/app`(슬래시 없음)으로 맞춰도 동작한다(같은 기록에서 이 형태로 `DB 연결 성공: appdb` 확인). 어느 쪽이든 **셋을 통일**한다.

### 4-3. SELinux: httpd가 외부(was01)로 접속 허용

```bash
setsebool -P httpd_can_network_connect 1
```

### 4-4. 방화벽 설정

```bash
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload
```

### 4-5. NTP 서버(chrony) 구성

**이유**: 폐쇄망은 외부 NTP 서버에 접근할 수 없으므로, web01을 자체 stratum 8 NTP 서버로 만들고 was01/db01이 참조하도록 한다.

```bash
vim /etc/chrony.conf
```
아래 내용을 추가/수정:
```
local stratum 8
allow 192.168.10.0/24
allow 10.10.10.0/24
```
```bash
systemctl enable --now chronyd
systemctl restart chronyd
firewall-cmd --permanent --add-service=ntp
firewall-cmd --reload
chronyc sources
```
> `chronyc sources`는 `systemctl restart chronyd` 직후에는 `^?`(아직 판단 불가)나 `^x`(다른 서버들과 시각이 크게 어긋나 잠정 제외)가 섞여 보이는 것이 정상이다. web01 기록의 첫 확인이 그랬다: `Reach`가 17~27(샘플이 몇 개뿐), 서버 4개가 모두 `^?`/`^x`, 오프셋이 −1.9초~+2.2초로 들쭉날쭉. **몇 분 뒤 `chronyc sources`를 다시 실행해 `^*`(선택된 서버) 하나와 `^+`(사용 가능)가 보이면 동기화된 것**이다. 다만 이 PC의 VM은 그렇게 되지 않을 수 있다. 재부팅 후(chronyd 가동 10분 안팎) 다시 본 web01은 `Reach 377`(최근 8번 응답 모두 성공)인데도 서버 3개가 모두 `^~`(측정값이 너무 들쭉날쭉)였고 `Last sample`이 약 `+15.5s`로 셋이 서로 비슷했다(IPv6 서버 1개는 원래 `^?`, `Reach 0`). 같은 시각 `journalctl -u chronyd`(또는 `systemctl status chronyd`의 아래쪽 로그)에는 `System clock wrong by -2.781065 seconds` → 71초 뒤 `System clock wrong by 3.383265 seconds`가 찍혔고, `Can't synchronise: no majority`, `Detected falseticker`, `Selected source`가 계속 번갈아 나왔다. 인터넷 서버들이 아니라 **VM 자신의 시계가 몇 초씩 앞뒤로 튀어서** chronyd가 기준 서버를 못 정하는 모습으로 보이며(추정), 이 프로젝트의 다른 증상(journald `Time jumped backwards`, 느린 부팅과 ssh)과 같은 뿌리일 가능성이 있지만 **원인은 미확정**이다. 이 로그들은 오류가 아니라 이 상태를 알려 주는 정상적인 메시지다. 이 프로젝트의 목적(폐쇄망에서 was01/db01이 web01을 기준으로 삼는 것)에는 web01이 외부와 정확히 맞는지보다 **§5-4와 §6-10에서 was01/db01의 `chronyc sources`가 web01을 `^*`로 잡는지**가 판정 기준이다. 폐쇄망으로 전환하면 외부 서버는 모두 `^?`가 되지만 `local stratum 8` 덕에 web01이 계속 시간을 내준다.

### 4-6. 사내 DNF 저장소 구성 (폐쇄망 대응), v3에서 lvm2 추가

**이유**: 실제 폐쇄망에서는 was01/db01이 인터넷 저장소에 접근할 수 없으므로, web01이 필요한 패키지만 미리 받아 자체 HTTP 저장소로 재배포하는 역할을 한다. (정정) 예전 가이드는 `dnf install --downloadonly --downloaddir=…`를 썼지만 이 방식에는 두 가지 함정이 있어(아래 ⚠️) `dnf download --resolve --alldeps --destdir=…`로 바꿨다.

```bash
dnf install -y dnf-plugins-core createrepo_c
mkdir -p /repo/rocky10/local
```

**패키지 + 전체 의존성 다운로드** (web01, 인터넷 연결 상태에서 1회 실행). v16에서 명령을 바꿨다:
```bash
dnf download --resolve --alldeps --destdir=/repo/rocky10/local \
  httpd mod_ssl \
  tomcat9 tomcat9-webapps tomcat9-admin-webapps \
  java-21-openjdk \
  postgresql-server postgresql-contrib \
  lvm2 \
  policycoreutils-python-utils
```
`--resolve --alldeps`는 **web01에 이미 설치돼 있는 패키지(httpd 계열, lvm2 등)까지 포함해** 의존성 전체를 받으므로 web01에 무엇이 깔려 있든 같은 결과가 나온다. `lvm2`는 db01의 LVM 구성(§6-2)에 필요해서 목록에 있다. `policycoreutils-python-utils`(`semanage`를 주는 패키지)는 §6-2와 §11-5에서 쓰는데, 인터넷이 되는 노드는 §3-4에서 외부 저장소로 이미 깔아 두기 때문에 저장소에 없어도 티가 나지 않다가, 인터넷이 안 되는 db02(§11-5 1))에서 `No match for argument`로 드러났다. 이미 받은 파일은 `[SKIPPED] … Already downloaded`로 건너뛰므로 다시 실행해도 안전하다(재현 기록).

재현 기록(2026-10-02): 아래 ⚠️ 2)로 파일이 사라진 web01에서 이 명령을 보강용으로 실행했을 때 해석된 패키지가 **429개**였고(진행 표시 `(…/429)`), 그중 193개는 이미 있어서 건너뛰고 236개를 새로 받았다. 이어서 `createrepo_c`가 `Directory walk done - 475 packages`를 찍었다(429 + §9-3의 HA 전용 46개). 처음부터 이 명령만으로 저장소를 만든 기록은 없어서 **'빈 디렉터리에서 시작해도 429개'인지는 미확인**이다. 이 429와 475는 목록에 `policycoreutils-python-utils`가 **없던** 때의 숫자이고, 그 패키지를 나중에 추가하자 15개가 더 늘어 `createrepo_c`가 `490 packages`를 찍었다(§11-5 1)).

**⚠️ 예전 방식(`dnf install --downloadonly --downloaddir=…`)을 쓰면 안 되는 이유 두 가지 (실제로 겪음)**

1) **이미 설치된 패키지는 받지 않는다.** web01은 §4-1에서 httpd를 먼저 깔았기 때문에 예전 방식의 결과(245개)에 httpd 계열 12개(`httpd`, `httpd-core`, `httpd-filesystem`, `httpd-tools`, `apr`, `apr-util`, `apr-util-lmdb`, `apr-util-openssl`, `mailcap`, `mod_http2`, `mod_lua`, `rocky-logos-httpd`)가 빠졌다(출력 첫머리 `Package httpd-… is already installed.`). was01/db01은 영향이 없었지만 web02를 로컬 저장소만으로 설치할 때(§10-2-1)는 문제가 된다. 새 명령은 이 12개를 처음부터 포함한다.

2) **받아 둔 rpm이 나중에 지워질 수 있다.**

- **증상**: web01에서 §4-6으로 저장소를 만들고(245개) §9-3으로 HA 패키지를 채워 `createrepo_c`가 `303 packages`를 찍었는데, 다음 날 was02의 `dnf install java-21-openjdk tomcat9 …`가 `[MIRROR] ModemManager-glib-…rpm: Status code: 404 for http://192.168.10.111/repo/…` → `Cannot download, all mirrors were already tried without success`로 실패했다. web01의 `ls /repo/rocky10/local/*.rpm | wc -l`는 303이 아니라 **58**이었다. `repodata`는 303개 목록을 그대로 갖고 있었기 때문에 dnf가 없는 파일을 찾아간 것이다(메타데이터는 파일 목록의 사진일 뿐, 파일 자체가 아니다).
- **개수가 정확히 맞아떨어졌다**: 303 = 245(§4-6 `--downloadonly`) + 12(`dnf download --destdir`로 채운 httpd 계열) + 46(§9-3의 HA 전용 rpm). 사라진 것은 245개뿐이고 남은 58 = 12 + 46이었다. §9-3에서 `mv`로 넣은 HA 110개 중 245개와 이름이 겹친 64개(110 − 46)도 함께 사라졌다.
- **원인 (강한 추정)**: 업스트림 dnf 소스를 확인하니, `--downloadonly`로 받은 파일의 경로를 `/var/cache/dnf/tempfiles.json`에 적어 두었다가 **다음에 패키지를 설치하는 성공한 `dnf` 작업이 끝날 때 그 경로의 파일을 지우도록** 돼 있다(`--downloadonly` 실행 끝에 찍히는 `The downloaded packages were saved in cache until the next successful transaction.`가 그 예고다). `--downloaddir`을 쓰면 그 경로가 곧 `/repo/rocky10/local/…`라서 저장소의 rpm이 지워진다. `dnf download --destdir`로 받은 파일과 `mv`로 넣은 파일은 이 기록에 올라가지 않아서 살아남았고, 위 숫자와 맞는다. 다만 **이 VM에 설치된 dnf 버전의 코드를 직접 본 것도, 삭제되는 순간을 본 것도 아니고** 어느 `dnf install`이 지웠는지는 기록으로 가릴 수 없었다(web01의 §9-3 8)이 유력한 후보). 이 설명이 틀려도 아래 방식으로 받으면 같은 문제를 피할 수 있다.
- **예전 방식으로 이미 만들었다면 지금 확인한다** (web01에서):
```bash
sudo cat /var/cache/dnf/tempfiles.json | head -c 400; echo    # /repo/rocky10/local/…rpm 경로가 보이면 '다음 설치 때 지워질 예약'이 걸린 상태
```
  예약이 보이면 다음 `dnf install`을 하기 전에 비운다(dnf 소스의 `empty()`가 하는 일과 같은 동작이지만 이 VM에서의 결과는 **미확인**):
```bash
echo '[]' | sudo tee /var/cache/dnf/tempfiles.json
```
  재현 기록(web01, 2026-10-03): 위 `cat … | head -c 400`이 `["/repo/rocky10/local/exiv2-libs-0.28.3-5.el10.x86_64.rpm", "/repo/rocky10/local/cups-libs-2.4.10-18.el10_2.x86_64.rpm", …]`처럼 **저장소 경로를 실제로 보여 줬고**, `echo '[]' | sudo tee …`가 `[]`를 출력했다. 즉 '`--downloaddir` 경로가 이 파일에 기록된다'는 부분은 확인했다. 다만 그 시점에 이 경로의 파일들이 이미 지워진 뒤였는지 아니면 다시 받은 뒤였는지는 기록으로 가릴 수 없고, 파일이 지워지는 순간과 `[]`로 비운 효과(이후 `dnf install`이 저장소를 지우지 않는지)는 **미확인**이다.
- **파일이 이미 줄었다면 복구**: 위 `dnf download --resolve --alldeps --destdir=…` 명령을 다시 실행하고, 메타데이터는 `--update`가 아니라 전체 재생성한다.
```bash
createrepo_c /repo/rocky10/local
restorecon -Rv /repo/rocky10/local/ | tail -3     # 출력이 없으면 라벨이 이미 맞는 것
ls /repo/rocky10/local/*.rpm | wc -l
```
  실패했던 클라이언트(was01/was02/db01)에서는 `sudo dnf clean metadata` 후 다시 설치한다(재현 기록: was02가 174개 패키지로 `Complete!`).

> **선택: 저장소를 작게 (v16, 미검증)**: 위 목록의 `java-21-openjdk`는 화면 출력용 라이브러리까지 끌고 와서 web01 기록에서 **245개 패키지, 약 180 MB(설치 크기 661 MB)** (예전 방식, web01에 이미 설치된 것을 뺀 숫자)가 됐고, was02 설치에서도 **174개 패키지, 159 MB(설치 589 MB)** 였다(`gtk3`, `mesa-dri-drivers`, `pipewire-*`, `llvm-libs`, `intel-vsc-firmware` 등). 서버(Tomcat)에는 화면이 필요 없으므로 `java-21-openjdk-headless`로 바꾸면 훨씬 줄 것으로 보이지만, `tomcat9` RPM이 headless만으로 설치되는지는 이 환경에서 확인하지 못했다. 바꾸려면 먼저 `dnf install --assumeno java-21-openjdk-headless tomcat9 tomcat9-webapps tomcat9-admin-webapps` 로 패키지 개수와 오류 여부를 미리 보고(`--assumeno`는 아무것도 설치하지 않는다), §5-1과 §10-2의 설치 명령도 같은 이름으로 맞춘다. 이미 만들었다면 **그대로 진행해도 문제없다**(재현 기록: was01, was02 모두 정상 설치되고 동작).

**저장소 메타데이터 생성**:
```bash
createrepo_c /repo/rocky10/local
```

**Apache로 `/repo` 노출**:
```bash
cat > /etc/httpd/conf.d/repo.conf <<'EOF'
Alias /repo /repo
<Directory "/repo">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
EOF
systemctl restart httpd
```

**SELinux 컨텍스트** (`/repo`는 기본 웹 콘텐츠 경로가 아니라서 그냥 두면 403이 난다):
```bash
semanage fcontext -a -t httpd_sys_content_t "/repo(/.*)?"
restorecon -Rv /repo
```
> 패키지 수백 개를 하나씩 `Relabeled ... to ...httpd_sys_content_t`로 찍기 때문에 출력이 수백 줄인 것이 정상이다(web01 기록: 250줄 넘게). 마지막 줄들에 `repodata/repomd.xml`이 보이면 끝난 것이다.

**web01 로컬 테스트**:
```bash
curl -I http://localhost/repo/rocky10/local/repodata/repomd.xml
```
`200 OK`가 나오면 성공. 404면 `createrepo_c` 안 돌린 것, 403이면 SELinux/권한 문제다.

**was01 / db01에서 로컬 저장소 등록**:

> ⚠️ **이 블록은 was01/db01용이다. web01에서는 실행하지 않는다.** web01은 저장소를 '제공'하는 서버라서 자기 자신을 저장소로 등록할 이유가 없다. web01 챕터 4 기록에서는 이 블록이 web01에서 실행돼 `local-web01.repo`가 만들어지고 `dnf config-manager --set-disabled baseos appstream extras`까지 적용되어, `dnf repolist`에 **`local-web01` 하나만** 남았다. 이 상태의 web01은 ① 로컬 저장소에 든 패키지 밖의 것을 설치하거나 업데이트할 수 없고, ② (예전 `--downloadonly` 방식으로 만든 저장소라면) httpd 계열이 빠져 있으며, ③ 저장소 파일이 web01 자신의 httpd에 의존한다(httpd가 죽으면 web01의 dnf도 실패). 특히 위 `dnf download`는 외부 저장소가 켜져 있어야 받아지므로, 이미 꺼 버렸다면 **먼저 되돌린다**(web01에서):

```bash
rm -f /etc/yum.repos.d/local-web01.repo
dnf config-manager --set-enabled baseos appstream extras
dnf repolist          # baseos / appstream / extras 가 보여야 함 (local-web01 은 없어야 함)
```

**아래 블록은 was01 / db01에서만 실행한다:**

```bash
cat > /etc/yum.repos.d/local-web01.repo << 'EOF'
[local-web01]
name=Internal Repo via web01
baseurl=http://192.168.10.111/repo/rocky10/local
enabled=1
gpgcheck=0
EOF

# 기존 온라인 저장소는 꺼서 dnf가 매번 타임아웃으로 헤매지 않게 함
dnf config-manager --set-disabled baseos appstream extras
```
(이 명령이 안 먹으면 `/etc/yum.repos.d/rocky.repo`를 열어 `[baseos]`, `[appstream]`, `[extras]` 섹션의 `enabled=1`을 `enabled=0`으로 직접 바꾼다.)

**was01/db01에서 접속 확인**:
```bash
curl -I http://192.168.10.111/repo/rocky10/local/repodata/repomd.xml
dnf repolist
```
`local-web01`만 뜨고 정상 응답이 오면 준비 완료다.

> **저장소를 이미 만들어서 새 패키지를 추가로 받은 경우**: web01에서 `createrepo_c --update /repo/rocky10/local`로 메타데이터만 갱신하면 되고(rpm 파일은 다시 받을 필요 없음), was01/db01에서는 `dnf clean metadata && dnf repolist`로 새 메타데이터를 반영하면 된다.

**저장소 개수 기록 + 백업 + (선택) 사전 검사 (권장)**: 저장소는 한 번 만들고 잊기 쉬운데, 이 프로젝트에서는 파일이 조용히 줄어든 적이 있었다(위 ⚠️ 2)).

🖥️ web01에서:
```bash
ls /repo/rocky10/local/*.rpm | wc -l                     # 지금 개수를 메모해 둡니다 (재현 기록: 475)
df -h /                                                  # 백업할 여유가 있는지 (재현 기록: 5.1G 여유)
sudo cp -a /repo/rocky10/local /root/repo-local-backup   # 저장소가 아닌 /root 아래에 둡니다
```
§9-3을 마친 뒤나 VM을 껐다 켠 뒤에 개수가 그대로인지 다시 세어 본다. 줄었다면 복구는 다음과 같다(복구 명령은 **실행해 본 적 없음**; `cp -n`은 이미 있는 파일을 덮어쓰지 않는다).
```bash
sudo cp -an /root/repo-local-backup/. /repo/rocky10/local/
sudo createrepo_c /repo/rocky10/local
sudo restorecon -Rv /repo/rocky10/local/ | tail -3
```

**(선택, 미실행) 필요한 의존성이 다 들어 있는지 사전 검사**: was01이나 db01처럼 로컬 저장소만 보는 노드에서, 아무것도 설치하지 않고 의존성만 계산해 보는 방법이다. `--installroot`로 빈 루트를 쓰면 그 노드에 이미 설치된 패키지와 무관하게 전체 의존성이 계산된다. 실행해 본 적이 없어 출력 모양은 **미확인**이다.
```bash
sudo dnf --installroot=/tmp/chk --releasever=10 install --assumeno \
  httpd mod_ssl tomcat9 tomcat9-webapps tomcat9-admin-webapps java-21-openjdk \
  postgresql-server postgresql-contrib lvm2 pacemaker corosync pcs resource-agents
sudo rm -rf /tmp/chk
```
`Transaction Summary`가 나온 뒤 `Operation aborted.`로 끝나면 의존성은 충분한 것이고, `nothing provides …`나 `No match for argument`가 나오면 그 패키지가 저장소에 없는 것이다. (HA 패키지는 §9-3을 마친 뒤에만 포함해서 실행한다.)

### 4-7. 커널 파라미터 튜닝 (WEB 역할)

```bash
cat > /etc/sysctl.d/99-web-tuning.conf <<'EOF'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
EOF
sysctl --system
```

### 4-8. 최종 확인

```bash
systemctl status httpd chronyd --no-pager
cat /proc/net/bonding/bond0
curl -I http://localhost/
```

> `curl -I http://localhost/`가 `403 Forbidden`으로 나와도 정상이다. 아직 `index.html`이 없어 Apache의 기본 환영 페이지(`Server: Apache/2.4.63 (Rocky Linux)`)가 그렇게 응답하는 것이다(web01 기록에서 확인). 마찬가지로 `curl http://localhost/app/`은 was01의 Tomcat이 뜨기 전(§5 이전)에는 `503 Service Unavailable`이 정상이다.

> `systemctl status httpd`의 로그에 `httpd.service: Referenced but unset environment variable evaluates to an empty string: OPTIONS`와 `AH00558 ...`가 보여도 정상이다(둘 다 안내성 메시지이고 서버는 `listening on: port 80`, `Started httpd.service`까지 갔다. web01 기록에서 확인). `chronyd`의 `Can't synchronise: no majority` 등은 위 §4-5의 설명대로다.

---

## 5. was01: Application Tier 구축

### 5-1. OpenJDK 설치

**이유**: Rocky Linux 10 AppStream에는 `java-17-openjdk` 패키지가 없다(21과 25만 제공). Spring Boot는 Java 21에서 정상 동작하므로 21을 사용한다.

```bash
dnf install -y java-21-openjdk
java -version
```
> **`Install 165 Packages` / 다운로드 150 MB / 설치 크기 577 MB가 나오는 것이 정상이다 (v16, 세 번째 재현 was01)**. `gtk3`, `mesa-dri-drivers`, `pipewire-*`, `llvm-libs` 같은 화면, 오디오용 의존성까지 딸려 오기 때문이고, 그 의존성이 모두 §4-6 로컬 저장소에 들어 있다는 확인이기도 하다(`Repository` 열이 전부 `local-web01`). 이 PC에서는 다운로드 약 2분에 설치까지 이어졌고, 끝나면 `java -version`이 `openjdk version "21.0.12.1"`을 보여야 한다. (`java-21-openjdk-headless`가 저장소에 있고 의존성으로 함께 설치되는 것은 확인됐지만, 그것만으로 tomcat9까지 설치되는지는 시험하지 않았다.)
> `java-21-openjdk-devel`은 로컬 저장소 다운로드 목록에 없어 설치 실패했던 이력이 있다(실행과 배포만 할 거면 devel 패키지는 필요 없다. 필요하면 §4-6 다운로드 목록에 추가한다).

### 5-2. Apache Tomcat 9 설치: v3, RPM 패키지로 통일

**이유(변경)**: 원래 가이드는 tar 압축 수동 설치(`/opt/tomcat`)를 안내했지만, 실제로는 §4-6에서 만든 로컬 저장소를 통해 **RPM 패키지(`tomcat9`)로 설치**되어 지금 그게 운영 중이다. 두 가지 설치본이 섞여 있으면 어느 쪽 설정 파일을 고쳐야 하는지 헷갈리는 문제가 생기므로(실제로 §5-3에서 이 문제가 발생했다), **RPM 설치 하나로 통일**한다.

```bash
dnf install -y tomcat9
systemctl list-unit-files | grep -i tomcat
# tomcat.service (disabled) 로 나오면 정상 — 서비스 이름은 "tomcat9"이 아니라 "tomcat"입니다
systemctl enable --now tomcat
systemctl status tomcat --no-pager
```

**실제 경로 확인** (RPM 설치는 tar 설치와 경로가 다르다. 아래 값을 기준으로 이후 작업한다):
```bash
systemctl show tomcat -p Environment
# 'Environment=NAME=' 한 줄만 나오는 것이 정상입니다. (v16 정정: 예전 문구 'CATALINA_BASE=…로 나옵니다'는 틀렸습니다 — 재현 기록 2번 모두 NAME= 뿐이었습니다)
journalctl -u tomcat --no-pager | grep 'options used'
# '-Dcatalina.base=/usr/share/tomcat …'가 보이면 CATALINA_BASE가 /usr/share/tomcat이라는 확인입니다
ls -l /var/lib/tomcat/webapps/     # 웹앱 배포 경로 — tomcat9-webapps를 설치하지 않았으므로 'total 0'이 정상
```

**JVM이 뜨는 데 시간이 걸린다. `enable --now` 직후 바로 확인하면 아무것도 안 나올 수 있다 (v16, 세 번째 재현 was01).** 그 기록에서는 `status`가 `since ...; 1s ago`, `Tasks: 3`인 시점에 곧바로 `ss -tlnp | grep 8080`을 쳤더니 출력이 없었고 `curl`은 `curl: (7) Failed to connect to localhost port 8080`이었다. 기다린 뒤에는 정상이었다: 서비스 시작 03:23:35 → `Server startup in [6251] milliseconds`가 찍힌 것이 03:25:14로 **약 1분 40초 뒤**였고(Tomcat 자체 기동은 6.2초, 나머지 시간이 왜 걸렸는지는 미확정), 그 뒤에야 `LISTEN … *:8080`(java, 서비스의 Main PID와 같은 프로세스)과 `HTTP/1.1 404`가 나왔다. 아래를 차례로 실행하고, 첫 줄에 `Server startup in [...] milliseconds`가 보일 때까지 수십 초씩(이 PC에서는 최대 2분 안팎) 기다렸다가 다시 한다:
```bash
journalctl -u tomcat --no-pager | grep -E 'Server startup|SEVERE'
ss -tlnp | grep 8080
curl -I http://localhost:8080/
```
`404`가 정상이다 (아직 앱을 배포하지 않았으니 컨텍스트가 없는 것뿐). `Server startup`이 안 보이고 `SEVERE`만 있으면 `journalctl -u tomcat -n 50 --no-pager`로 원인 줄을 확인한다.

> **`/opt/tomcat`이 이미 있다면**: 이전에 tar 설치를 시도했던 흔적이다. 실제로는 쓰이지 않는 폴더이니(`CATALINA_BASE`가 `/usr/share/tomcat`이므로) 혼란을 막기 위해 정리한다.

```bash
systemctl list-unit-files | grep tomcat   # tomcat.service가 RPM 것 하나만 있는지 확인
rm -rf /opt/tomcat
```

### 5-3. AJP 커넥터 활성화 (Ghostcat 취약점 대응): v3, 올바른 파일 경로로 정정

**이유**: Tomcat 9.0.31 이후 버전은 AJP 커넥터가 기본적으로 비활성화되어 있다(2020년 발견된 Ghostcat, CVE-2020-1938 대응). web01의 mod_proxy_ajp가 연결되려면 이걸 켜야 한다.

**중요**: Tomcat은 항상 `${CATALINA_BASE}/conf/server.xml`을 읽는다. 지금 `CATALINA_BASE=/usr/share/tomcat`이므로 수정할 파일은 아래 경로다(예전에 `/opt/tomcat/conf/server.xml`을 고쳤다면 반영되지 않은 상태이니 다시 확인한다).

**방법 1 (권장): 스크립트로 정확히 추가 (v16)**: 손으로 vim 편집하다가 주석 위치, `address`, `secretRequired`를 놓쳐 여러 번 고쳐 쓰는 일이 재현 중에 실제로 있었다(was01 재현 기록 기준 `vim server.xml` 6회). 아래 스크립트는 **주석 밖에 살아있는 AJP Connector가 없을 때만** 아래 블록을 `</Service>` 바로 앞에 추가하고, 원본은 `server.xml.orig`로 백업한다(was01 전용. `address`가 `10.10.10.12`).

🖥️ was01에서 (root):
```bash
python3 - <<'PY'
import re, shutil, sys
p = "/usr/share/tomcat/conf/server.xml"
s = open(p, encoding="utf-8").read()

# 주석(<!-- -->)을 걷어낸 '실제로 살아있는' 부분에 AJP Connector가 이미 있으면 중복 추가하지 않고 멈춥니다.
if re.search(r'protocol="AJP/1\.3"', re.sub(r"<!--.*?-->", "", s, flags=re.S)):
    print("⚠ 이미 활성화된 AJP Connector가 있습니다 → 이 스크립트는 건드리지 않았습니다. 아래 '방법 2 (수동)'로 그 블록의 address/secretRequired를 고치세요.")
    sys.exit(1)

shutil.copy(p, p + ".orig")                      # 원본 백업
block = '''
    <Connector protocol="AJP/1.3"
               address="10.10.10.12"
               port="8009"
               redirectPort="8443"
               secretRequired="false" />
'''
i = s.rfind("</Service>")                        # 마지막 </Service> 바로 앞에 추가
open(p, "w", encoding="utf-8").write(s[:i] + block + s[i:])
print("✅ AJP Connector 추가 완료 (원본 백업: server.xml.orig)")
PY
```

이 스크립트(또는 수동 편집)의 결과로 `server.xml`에 아래 블록이 들어가 있어야 한다:
```xml
<Connector protocol="AJP/1.3"
           address="10.10.10.12"
           port="8009"
           redirectPort="8443"
           secretRequired="false" />
```
- **방법 2 (수동, `vim /usr/share/tomcat/conf/server.xml`)**: 기본 파일에는 AJP 블록이 **주석 처리된 채** `address="::1"`로 들어 있고 `secretRequired` 속성이 없다. 주석만 풀고 저장하면 두 증상이 나온다. ① `ss -tnlp | grep 8009`에 `[::1]:8009`만 보임(web01에서 접근 불가), ② `journalctl -u tomcat`에 `The AJP Connector is configured with secretRequired="true" but the secret attribute is either null or ""` 예외와 함께 커넥터 시작 실패. 그러니 위 블록처럼 `address`와 `secretRequired="false"`를 **둘 다** 넣어야 한다.
- `address`를 서비스망 IP로 명시해 관리망/외부에서는 AJP 포트에 접근하지 못하도록 제한한다.
- `secretRequired="false"`는 실습 편의를 위한 설정이다. 운영 환경이라면 `secret` 값을 지정하고 web01의 `ProxyPass` 설정에도 동일한 secret을 넣는 것이 더 안전하다.

```bash
systemctl restart tomcat
```

**반드시 아래로 실제 리스닝 여부를 확인한다** (예전엔 이 확인 단계가 없어서 설정이 반영 안 된 걸 놓쳤다):
> ℹ️ **`restart` 뒤 기동 시간은 첫 기동(§5-2)보다 훨씬 짧았다 (v16, 세 번째 재현 was01).** §5-2의 첫 기동은 약 1분 40초 걸렸지만, 이 절의 `systemctl restart tomcat` 뒤에는 바로 이어서 친 `ss -tnlp | grep 8009`에서 이미 `LISTEN`이 보였다(첫 기동만 느렸던 이유는 미확정. 설치 직후라 디스크 캐시가 비어 있었을 가능성, 추정). 그래도 아무것도 안 나오면 설정 탓으로 단정하지 말고 먼저 `journalctl -u tomcat --no-pager | grep 'Server startup' | tail -1`로 **재시작 이후 시각의** `Server startup` 줄이 찍혔는지 확인한 뒤 다시 `ss`를 친다(`tail -1`이 가장 최근 줄이다).
```bash
ss -tnlp | grep 8009
```
정상 출력은 `LISTEN 0 100 [::ffff:10.10.10.12]:8009 *:* users:(("java",pid=…))` 형태다(세 번째 재현 was01). `[::ffff:10.10.10.12]`는 IPv4 주소 `10.10.10.12`를 자바 소켓이 'IPv4-mapped IPv6' 표기로 보여주는 것이라 **정상**이고, `address="10.10.10.12"`가 적용됐다는 뜻이다. `[::1]:8009`만 보이면 위 '방법 2'의 증상이다.
결과가 안 나오면 위 `server.xml` 경로를 다시 확인하고 `systemctl status tomcat -l`, `journalctl -u tomcat -n 50 --no-pager`로 에러를 확인한다.

### 5-4. NTP 클라이언트 설정 (web01 참조)

```bash
dnf install -y chrony
vim /etc/chrony.conf
```
기존 `pool` 라인들을 지우거나 주석 처리하고 아래 한 줄만 추가:
```
server web01 iburst
```
```bash
systemctl enable --now chronyd
systemctl restart chronyd
chronyc sources
```
> 재시작 직후에는 `^? web01  8  6  1  2  -65.4s[ -65.4s] +/- 20ms`처럼 `^?`(아직 판단 불가), `Stratum 8`(web01의 `local stratum 8`), `Reach 1`(샘플 1개)로 보이는 것이 정상이고, 오프셋이 **수십 초**(이 기록은 −65.4초)여도 놀랄 필요 없다. 재시작 뒤 처음 몇 번의 측정에서 chronyd가 시계를 한 번에 맞춘다(Rocky 기본 설정의 `makestep`). 1~2분 뒤 `chronyc sources`를 다시 쳐서 `web01` 앞이 `^*`로 바뀌고 `Reach`가 올라가면 성공이다(재확인 결과는 §5-8: 05:49에 `^* web01`, Reach 377). 편집 확인은 `tail -1`로는 부족하다. 기존 `pool` 줄이 남았는지 `grep -E '^(pool|server)' /etc/chrony.conf`로 본다(`server web01 iburst` 한 줄만 나와야 함).

### 5-5. 방화벽: AJP 포트는 web01에서만 허용

> v16: 규칙을 **한 줄**로 바꿨다. `--add-rich-rule=\` 뒤에서 줄이 끊기면 `Error: INVALID_RULE: empty rule`이 난다(was01 재현 기록).

```bash
firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="10.10.10.11/32" port protocol="tcp" port="8009" accept'
firewall-cmd --reload
firewall-cmd --list-rich-rules
```
`--list-rich-rules`에 `rule family="ipv4" source address="10.10.10.11/32" port port="8009" protocol="tcp" accept` 한 줄이 나오면 등록된 것이다(세 번째 재현 was01 확인).

규칙이 실제로 '누구는 열고 누구는 막는지'는 접속을 시도해 봐야 안다. web01에서는 `OPEN`, db01에서는 `BLOCKED`가 나와야 한다:
```bash
timeout 3 bash -c '</dev/tcp/10.10.10.12/8009' && echo OPEN || echo BLOCKED
```
재현 기록: web01은 `OPEN`, db01은 아래처럼 `BLOCKED`였다.
```
bash: connect: No route to host
bash: line 1: /dev/tcp/10.10.10.12/8009: No route to host
BLOCKED
```
> `No route to host`는 경로가 없다는 뜻이 아니라 방화벽이 거부한 결과로 보인다. db01↔was01 ping은 양방향으로 통과했고, firewalld는 허용되지 않은 접속을 기본적으로 이렇게 거부하는 것으로 알려져 있다(이 PC에서 방화벽을 열어 원인을 다시 확인한 것은 아니다). 트러블슈팅 표의 'was01→db01 … No route to host' 항목과 같은 모양이다.

### 5-6. Spring Boot 앱(WAR) 배포: v5, Maven 설치부터 실전 배포까지 전체 절차

**결정된 방향**: Tomcat9 유지, `pom.xml`은 **Spring Boot 2.7.18**(javax 기반 마지막 안정 버전)로 구성한다. Spring Boot 3.0부터는 `jakarta.*` 네임스페이스(Jakarta EE 9+)를 쓰는데 이건 Tomcat 10.1 이상이 필요해서, Tomcat9(`javax.*`)와는 궁합이 안 맞는다. was01의 Tomcat9 + AJP는 이미 §5-3에서 `ss -tnlp`로 8009 리스닝까지 검증된 인프라라, 이걸 건드리지 않고 애플리케이션(자바) 쪽만 맞추는 이 방향이 실습에서 가장 안전했고 실제로 끝까지 성공했다.

#### 5-6-1. 개발 PC(Windows)에 Maven 준비

**먼저 Maven Wrapper가 이미 있는지 확인**: Spring Initializr로 만든 프로젝트라면 대개 `mvnw.cmd`가 이미 포함돼 있어서 별도 설치 없이 바로 쓴다.
```powershell
dir <프로젝트 폴더>\app\mvnw.cmd
```
있으면 아래부터는 전부 `mvn` 대신 `.\mvnw.cmd`를 쓰면 된다. **Maven을 따로 설치할 필요가 없다.** (세 번째 재현: `<프로젝트 폴더>\app\mvnw.cmd` 있음, 개발 PC의 `java -version`은 Temurin 17.0.20.1 → 아래 `pom.xml`의 `java.version` 17과 일치.) 래퍼가 실제로 도는지는 아래 세 줄로 미리 확인해 두면 빌드 때 헤매지 않는다(**아직 실행해 보지 않은 확인법**):
```powershell
dir <프로젝트 폴더>\app\.mvn\wrapper      # maven-wrapper.properties 가 있어야 함 (래퍼 설정 파일)
javac -version                          # 'javac 17…'이 나와야 JDK입니다 (java -version만으로는 JRE인지 JDK인지 모릅니다)
cd <프로젝트 폴더>\app; .\mvnw.cmd -v      # 첫 실행은 Maven 본체를 내려받느라 시간이 걸립니다(PC는 인터넷이 됩니다)
```
`mvnw.cmd -v`가 'JAVA_HOME not found'로 멈추면 `JAVA_HOME`을 JDK 설치 폴더로 지정해야 하는 (오래된) 래퍼다. 없다면 Java부터 확인(Maven은 JDK 필요):
```powershell
java -version
```
그 다음 Maven 수동 설치(공식 문서 권장 방법. winget에 Apache 공식 패키지가 없다):
1. https://maven.apache.org/download.cgi 에서 **Binary zip archive** 다운로드
2. `C:\apache-maven` 등 원하는 위치에 압축 해제
3. PATH에 `bin` 폴더 추가:
   ```powershell
   [Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\apache-maven\bin", "User")
   ```
4. **PowerShell 창을 닫고 새로 열기** (PATH 변경은 새 터미널부터 적용됨)
5. 확인: `mvn -version`

**프로젝트의 자바 파일이 어디 있는지 모르겠으면** 아래로 전체 목록을 뽑아 확인한다:
```powershell
cd <프로젝트 폴더>\app
Get-ChildItem -Recurse -Filter *.java
```
이 프로젝트는 패키지 `com.example.app` 아래에 `AppApplication.java`(메인 클래스), `HealthController.java`, `ServletInitializer.java` 3개로 구성되어 있다(`src\main\java\com\example\app\` 폴더).

#### 5-6-2. pom.xml: 전체 파일 (일부만 붙여넣지 말고 통째로 교체)

> ⚠️ **실제로 겪은 문제**: `<parent>` 조각만 복사해서 붙여넣다가 그걸 감싸는 `<project>...</project>` 태그까지 함께 지워져서 XML 자체가 깨진 적이 있었다(`Expected root element 'project' but found 'parent'` 에러). 아래는 조각이 아니라 **파일 전체**이니, `<프로젝트 폴더>\app\pom.xml`을 열어 안의 내용을 통째로 아래로 바꿔치기한다.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>2.7.18</version>
        <relativePath/>
    </parent>

    <groupId>com.example</groupId>
    <artifactId>app</artifactId>
    <version>0.0.1-SNAPSHOT</version>
    <packaging>war</packaging>
    <name>app</name>

    <properties>
        <java.version>17</java.version>
    </properties>

    <dependencies>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-jdbc</artifactId>
        </dependency>
        <dependency>
            <groupId>org.postgresql</groupId>
            <artifactId>postgresql</artifactId>
            <scope>runtime</scope>
        </dependency>
        <!-- 내장 톰캣은 빼고 서블릿 API만 provided로 (외부 Tomcat9에 배포하므로) -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-tomcat</artifactId>
            <scope>provided</scope>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-maven-plugin</artifactId>
            </plugin>
        </plugins>
    </build>
</project>
```
`groupId`/`artifactId`를 `com.example`/`app`으로 맞춰서, 빌드 결과물이 지금까지 계속 받아오던 파일명(`app-0.0.1-SNAPSHOT.war`) 그대로 나온다. `java.version`은 개발 PC의 Java(Temurin 17)에 맞췄다. was01의 Java 21과는 별개라 문제없다.

코드에서 `jakarta.servlet.*`, `jakarta.persistence.*` 등을 쓰고 있었다면 전부 `javax.servlet.*`, `javax.persistence.*`로 되돌려야 한다.

#### 5-6-3. 메인 클래스 수정: `AppApplication.java`

새로 만드는 게 아니라 **이미 있는 파일**(`src\main\java\com\example\app\AppApplication.java`)을 연다. 클래스 이름은 그대로 두고 `SpringBootServletInitializer`만 추가:
```java
package com.example.app;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.boot.web.servlet.support.SpringBootServletInitializer;

@SpringBootApplication
public class AppApplication extends SpringBootServletInitializer {

    @Override
    protected SpringApplicationBuilder configure(SpringApplicationBuilder builder) {
        return builder.sources(AppApplication.class);
    }

    public static void main(String[] args) {
        SpringApplication.run(AppApplication.class, args);
    }
}
```

> ⚠️ **`ServletInitializer.java`는 지운다. 재현 기록에서 앱이 두 번 기동됐다.** §5-6-1의 파일 목록에 있는 세 번째 파일 `ServletInitializer.java`(Spring Initializr가 War 패키징을 고르면 기본으로 만들어주는 파일)도 `SpringBootServletInitializer`를 상속한다. 위처럼 `AppApplication`이 직접 상속하고 있으면 둘이 겹친다.

was01 재현 기록의 Tomcat 로그다. Spring 배너가 두 번 나오고 그 사이에 `Root context already created (using as parent).`가 찍혔다:
```text
Started AppApplication in 159.89 seconds (JVM running for 322.901)
Root context already created (using as parent).
Filter errorPageFilter was not registered (possibly already registered?)
Started ServletInitializer in 7.327 seconds (JVM running for 330.538)
```
서비스는 이대로도 동작했다(`/app/db-check`가 404가 아니라 500, 즉 컨트롤러까지 도달). 다만 앱이 두 번 올라오고(이 PC에서는 첫 기동이 159초), `errorPageFilter` 경고도 이 중복에서 나온 것으로 보인다(로그 모양으로 본 추정이다). **해결**: 개발 PC(PowerShell)에서 빌드 전에 지운다.
```powershell
del <프로젝트 폴더>\app\src\main\java\com\example\app\ServletInitializer.java
```
시계 설정(§5-8)을 고치고 재부팅한 was01에서도 `Started AppApplication in 6.171 seconds (JVM running for 46.854)`와 `Started ServletInitializer in 0.524 seconds (JVM running for 47.542)`가 **둘 다** 찍혔다(이 WAR는 `ServletInitializer.java`를 지우기 전에 빌드한 것). 그러므로 이중 기동 자체는 두 `Started …` 줄로 확인된 사실이고, `errorPageFilter` 경고가 이 중복에서 나온다는 부분만 여전히 추정이다. 삭제 후 `Started` 줄이 하나만 남는지는 미확인이다.
`AppApplication`이 `configure(...)`에서 `sources(AppApplication.class)`를 이미 지정하므로 이 파일 없이도 War 배포가 된다. **삭제 후 배너가 한 번만 나오는지는 아직 확인하지 못했다(미확인).** 이미 빌드하고 배포했다면 급하지 않으니, 다음에 다시 빌드할 때 같이 지운다.

#### 5-6-4. DB 연동 확인용 엔드포인트: `HealthController.java`

같은 패키지 폴더(`com\example\app\`)에 만들어야 컴포넌트 스캔에 잡힌다.

> ⚠️ **실제로 겪은 문제**: WAR 파일명이 `app.war`이면 Tomcat이 자동으로 컨텍스트 경로를 `/app`으로 잡는다. `/app`은 Tomcat이 이미 붙여주는 접두어이므로, **`@GetMapping`에 `/app`을 또 붙이면 안 된다**(붙이면 컨텍스트 경로 제거 후 남는 경로와 안 맞아 404가 난다. 실제로 겪은 문제다).

```java
package com.example.app;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.SQLException;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HealthController {
    @Autowired
    private DataSource dataSource;

    @GetMapping("/db-check")   // "/app"을 붙이지 않음 — 컨텍스트 경로가 이미 /app이므로
    public String dbCheck() throws SQLException {
        try (Connection conn = dataSource.getConnection()) {
            return "DB 연결 성공: " + conn.getCatalog();
        }
    }
}
```

#### 5-6-5. application.properties

🖥️ **개발 PC(Windows)에서** 프로젝트 안의 이 파일을 편집한다. was01이나 db01에서 하는 작업이 아니다. 메모장으로 열려면 PowerShell에서:
```powershell
notepad <프로젝트 폴더>\app\src\main\resources\application.properties
```
`src\main\resources\application.properties`:
```properties
spring.application.name=app
spring.datasource.url=jdbc:postgresql://10.10.10.13:5432/appdb
spring.datasource.username=app_user
spring.datasource.password=여기에_직접_정한_비밀번호_입력
```
> ⚠️ **비밀번호는 빌드(§5-6-6) *전에* 넣어야 한다 (v16).** `application.properties`는 빌드할 때 WAR 안에 그대로 들어가므로, 이미 빌드한 뒤에 파일을 고쳤다면 `.\mvnw.cmd clean package -DskipTests`를 **다시** 실행해 새 WAR를 만들고 was01에 다시 배포해야 반영된다(세 번째 재현에서는 자리표시자 상태로 먼저 빌드가 끝나 있었다. 이 PC에서 빌드는 5초 남짓). 비밀번호는 **영문과 숫자만**으로 정한다. 공백, 따옴표(`'`), `#`, `\`, 한글이 들어가면 `.properties` 파일이나 §6-8의 SQL 문자열에서 문제가 생기기 쉽다(실습용 값이므로 실제 쓰는 비밀번호는 쓰지 않는다). 그리고 이 값을 실제 가이드나 저장소에 커밋하지 않는다.
> ⚠️ **`password=` 뒤에 실제로 사용할 비밀번호를 직접 입력한다.** §6-8에서 `CREATE USER`할 때 지정한 값과 정확히 같아야 한다. (자리표시자 문구를 안 바꾸고 그대로 SQL에 실행하면 SQL 문법 오류 없이 "그 문구 자체"가 진짜 비밀번호로 등록돼버리는 실수가 실제로 있었다. §6-8 참고.)

#### 5-6-6. 빌드: 로컬 테스트는 반드시 건너뛰기

```powershell
cd <프로젝트 폴더>\app
.\mvnw.cmd clean package -DskipTests
```
> ⚠️ **`-DskipTests`를 꼭 붙인다.** `mvn package`는 기본적으로 테스트(`AppApplicationTests`)를 같이 돌리는데, 이 테스트는 스프링 컨텍스트를 실제로 띄우면서 `10.10.10.13:5432`(db01)에 접속을 시도한다. `10.10.10.0/24`는 VirtualBox 내부 전용망(intnet "svc-net")이라 **호스트 PC(개발 PC)에서는 애초에 닿지 않는 네트워크**라서, `-DskipTests` 없이는 로컬 빌드가 항상 테스트 단계에서 실패한다(`Failed to configure a DataSource` / `Failed to determine a suitable driver class`). 실제 동작 확인은 어차피 was01에 배포한 뒤 curl로 하므로 이 테스트를 억지로 통과시킬 필요가 없다.

`[INFO] BUILD SUCCESS`가 뜨면 `target\app-0.0.1-SNAPSHOT.war`가 생성된다.

#### 5-6-7. war를 was01로 전달

개발 PC(PowerShell)의 `target` 폴더에서 파이썬 내장 웹서버로 잠깐 띄운다:
```powershell
cd <프로젝트 폴더>\app\target
python -m http.server 8000
```
> 이 창은 열어둔다(요청이 올 때까지 대기). 관리망 호스트온리 어댑터의 호스트 쪽 주소가 `192.168.10.1`이라 was01에서 이 주소로 접근된다.

was01에서:
```bash
sudo curl -o /var/lib/tomcat/webapps/app.war http://192.168.10.1:8000/app-0.0.1-SNAPSHOT.war
sudo rm -rf /var/lib/tomcat/webapps/app   # 이전에 풀린 폴더가 남아있으면 새 war로 안 갈아끼워지는 경우가 있어 먼저 정리
sudo chown tomcat:tomcat /var/lib/tomcat/webapps/app.war
sudo chmod 644 /var/lib/tomcat/webapps/app.war
sudo systemctl restart tomcat
```
> ⚠️ **`sudo`를 반드시 붙인다.** `vagrant ssh`로 접속하면 `root`가 아니라 `vagrant` 계정이다. `/var/lib/tomcat/webapps/`는 `tomcat` 계정 소유라 `sudo` 없이 `curl -o`로 쓰려고 하면 `Permission denied`로 조용히 실패한다(에러가 눈에 잘 안 띈다). 이때 다운로드가 중간에 끊기면서 개발 PC의 `python -m http.server`가 `ConnectionResetError`를 내는 것처럼 보이는데, 파이썬 서버 자체는 문제가 없고 원인은 was01의 권한 문제다.

> ⏱ **재시작 뒤 4분 넘게 걸릴 수 있다.** was01 재현 기록(§5-8 시계 설정 전): WAR 포함 재시작이 `Deployment of web application archive [/var/lib/tomcat/webapps/app.war] has finished in [248,736] ms`, `Server startup in [255146] milliseconds`(약 4분 15초)였고, 대부분은 Spring 첫 기동(`Started AppApplication in 159.89 seconds`)이었다. 이 PC에서는 정상 범위로 보이며, 그 사이의 404나 연결 실패는 실패가 아니다. `sudo journalctl -u tomcat --no-pager | grep -E 'Server startup|SEVERE'`에서 `Server startup`이 보일 때까지 기다린다. 왜 이렇게 오래 걸리는지는 **미확정**이다. 다만 시계 설정(§5-8)을 고치고 재부팅한 뒤 같은 WAR로 다시 재면 `Started AppApplication in 6.171 seconds`, `Server startup in [24716] milliseconds`(약 25초)로 약 10배 빨라졌다(§5-8 표).

> ⚠️ **§5-6-7 시점에는 db01이 아직 준비 전이다 (§6에서 만든다).** 그래서 여기서 `curl http://localhost:8080/app/db-check`가 `DB 연결 성공`이 아니라 오류로 나오는 것은 정상일 수 있다. 그 확인은 §6-8까지 끝낸 뒤 §7에서 다시 한다. 지금 확인할 것은 'WAR 배포 자체'다: `sudo journalctl -u tomcat -n 50 --no-pager | grep -i 'app.war'`에 배포 로그가 있는지 확인하고, `application.properties`의 비밀번호가 §6-8에서 만들 `app_user` 비밀번호와 같도록 지금 정해 둔다. (was01 재현 기록: 앱은 DB 없이도 기동됐고, 이 시점의 `curl http://localhost:8080/app/db-check`는 HTTP 500 JSON(`"path":"/app/db-check"`)이었다. 500은 404가 아니라 요청이 컨트롤러까지 도달했다는 뜻이다. 예외의 원인 줄은 확인하지 못해서 'DB 미구축 때문'은 추정이다.)
> 처음 `python -m http.server 8000`을 켜면 Windows 방화벽 경고창이 뜰 수 있다. 그때 '개인 네트워크' 허용을 하지 않으면 was01의 `curl`이 응답 없이 멈출 수 있다(일반적으로 알려진 동작이고 이 PC의 기록은 없다).

**war 안에 원하는 클래스가 실제로 포함됐는지 확인하고 싶다면** (선택 사항. Rocky 최소 설치엔 `unzip`이 기본으로 없으니 §3-4에서 미리 설치해두거나, JDK의 `jar` 명령을 쓰려면 `java-21-openjdk-devel`이 필요하다. 코드 자체를 개발 PC에서 이미 확인했다면 이 단계는 생략해도 된다):
```bash
unzip -l /var/lib/tomcat/webapps/app.war | grep -i HealthController
```

**로그 확인: was01에서 (`journalctl`은 리눅스 명령이라 Windows PowerShell에서 치면 'CommandNotFound'가 난다)** (RPM 설치본은 `/opt/tomcat/logs/catalina.out` 파일이 없다. journald로 나간다):
```bash
sudo journalctl -u tomcat -n 30 --no-pager
```

**배포 확인**:
```bash
curl http://localhost:8080/app/db-check
```
`DB 연결 성공: appdb`처럼 나오면 성공이다. 이 단계는 db01의 PostgreSQL이 서비스망 IP에서 리스닝하고 있어야 통과되니(§6-7), 안 되면 거기부터 다시 확인한다.

### 5-7. 커널 파라미터 튜닝 (WAS 역할)

```bash
cat > /etc/sysctl.d/99-was-tuning.conf <<'EOF'
vm.swappiness = 10
fs.file-max = 100000
EOF
sysctl --system

cat > /etc/security/limits.d/tomcat.conf <<'EOF'
tomcat soft nofile 65536
tomcat hard nofile 65536
EOF
```

> ⚠️ **`limits.d/tomcat.conf`는 systemd로 뜨는 tomcat에는 적용되지 않는다 (재현 기록으로 확인).** `/etc/security/limits.d/`는 PAM으로 로그인하는 세션에만 적용되고, `tomcat.service`의 한도는 유닛의 `LimitNOFILE=`이 정한다. 실제 값은 이렇게 본다:

```bash
grep 'open files' /proc/$(systemctl show -p MainPID --value tomcat)/limits
```

> was01 재현 기록의 출력은 `Max open files  524288  524288  files`였다. 65536이 아니므로 위 파일은 적용되지 않았지만, 실제 한도(524288)가 이미 더 커서 이 PC에서는 조치가 필요 없다(그 값이 systemd 기본값인지 JVM이 올린 것인지는 확인하지 않았다). 한도를 65536으로 정확히 맞추고 싶을 때만 `/etc/systemd/system/tomcat.service.d/limits.conf`에 `[Service]` / `LimitNOFILE=65536`을 넣고 `systemctl daemon-reload` 후 Tomcat을 재시작한다(이 방식은 실행해 본 기록이 없다).

### 5-8. 최종 확인

```bash
systemctl status tomcat chronyd --no-pager
curl -I http://localhost:8080/
ss -tnlp | grep -E '8080|8009'
```

정상 결과(was01 재현 기록): `curl -I`는 `HTTP/1.1 404`(루트 컨텍스트가 없어서 정상), `ss`는 `*:8080`과 `[::ffff:10.10.10.12]:8009`이다.

`systemctl status chronyd`의 `active (running)`은 데몬이 떠 있다는 뜻일 뿐 web01과 맞았다는 뜻이 아니다. 동기화 여부는 아래로 확인한다:
```bash
chronyc sources
chronyc tracking
```
`chronyc sources`에서 `web01`이 `^*`이면 통과다. was01 재현 기록은 `^? web01 … -65.4s`(§5-4)에서 시작했고, `journalctl -u chronyd`에는 `Can't synchronise: no selectable sources`와 `System clock wr…ds`(`System clock wrong by … seconds`가 화면에서 잘린 것)가 04:36~04:57 사이 번갈아 반복됐다. 이후 재확인(05:49)에서는 `^* web01`(Stratum 8, Poll 6, Reach 377, LastRx 19)에 도달했다. 통과 기준은 충족이다. 다만 같은 시점의 `chronyc tracking`은 이랬다:
```text
Reference ID    : C0A80A6F (web01)
Stratum         : 9
System time     : 3.884179354 seconds fast of NTP time
Last offset     : +1.421995878 seconds
RMS offset      : 27.077693939 seconds
Frequency       : 1255.873 ppm fast
Residual freq   : -1208.858 ppm
Skew            : 1125.045 ppm
Root dispersion : 1.216468334 seconds
Update interval : 64.9 seconds
```
`^*`는 붙었지만 시계가 안정적이지는 않다. 시스템 시각이 NTP 시각보다 3.9초 빠르고, 주파수 오차 추정이 1255 ppm(보통 수십 ppm 수준)에 skew도 1125 ppm이라 값이 수렴하지 못한다(`RMS offset`은 처음의 −65초 보정이 섞인 장기 평균이라 그 값만으로 판단하지는 않는다). was01과 web01 중 어느 쪽 시계가 흔들리는지는 구분하지 못했다.

세 VM(web01, was01, db01) 모두 `cat /sys/devices/system/clocksource/clocksource0/current_clocksource`가 `acpi_pm`이었다. §16-10에서 같은 PC의 db01/db02가 이 상태였고, VM을 끄고 `--paravirtprovider kvm`을 준 뒤 `tsc`가 되면서 db02의 chrony RMS가 267 ms에서 6 ms로 내려갔다. 그래서 세 대에 같은 방법을 적용했다(`vagrant halt <이름>` → `VBoxManage modifyvm 3t-r10-<이름> --paravirtprovider kvm` → `vagrant up <이름>`).

적용 결과(재현 기록): 세 VM 모두 `tsc`로 바뀌었고, 재부팅 뒤 bond0, 관리망 IP와 서비스(firewalld, chronyd 등)는 그대로였다(was01 `10.10.10.12`, db01 `10.10.10.13`+`.23`, web01 `10.10.10.11`). 가장 뚜렷한 변화는 web01의 유휴 부하다:

| web01 (유휴) | 적용 전 | 적용 후 |
|---|---|---|
| `top -H -b -n 2 -d 5`의 두 번째 샘플 | `18.1 sy`, `8.0 si`, `73.9 id` | `0.2 sy`, `97.0 id` |
| 두 번째 샘플의 상위 스레드 | sshd-session 8.2%, httpd 스레드 4개 1.0~2.7%, `xfsaild` 1.9%, `irq/9-acpi` 1.8% | 가장 높은 것이 0.2% |
| httpd `CPUUsageNSec`의 60초 증가분 | 약 4.86초 | 116 ms |

적용 후 `top`은 부팅 19분 시점의 5초 샘플 1회, `CPUUsageNSec`도 1회 측정이다. 재부팅 자체의 효과를 완전히 분리한 것은 아니다. was01의 Tomcat 기동 시간과 `chronyc tracking` 변화는 아래 표에 추가했다.

| was01 Tomcat (같은 WAR) | 적용 전 | 적용 후 |
|---|---|---|
| `Server startup in [...] milliseconds` | 255146 (약 4분 15초) | 24716 (약 25초) |
| 첫 `Started AppApplication in …` | 159.89초 | 6.171초 |
| 둘째 `Started ServletInitializer in …` | 7.327초 | 0.524초 |

적용 후는 재부팅 뒤 첫 기동 1회 측정이다(`sudo journalctl -b -u tomcat --no-pager | grep -E 'Started (AppApplication|ServletInitializer)|Server startup'`). 시계 설정과 재부팅이 함께 일어나서 시계가 원인이라고 분리해 증명한 것은 아니지만, 같은 WAR가 약 10배 빨라졌다. 두 `Started` 줄이 모두 찍힌다는 것은 `ServletInitializer.java`를 지우기 전이라는 뜻이다(§5-6-3).

was01 `chronyc tracking` (적용 전은 05:49, 적용 후는 15:43 UTC 측정):

| 항목 | 적용 전 | 적용 후 |
|---|---|---|
| Stratum | 9 | 4 |
| System time | 3.884 s fast | 0.0000778 s slow (약 78 µs) |
| RMS offset | 27.08 s | 0.000412 s |
| Frequency | 1255.873 ppm fast | 44.915 ppm slow |
| Skew | 1125.045 ppm | 0.123 ppm |
| Root dispersion | 1.216 s | 0.0015 s |
| Update interval | 64.9 s | 1029.2 s |

시스템 시각 오차, 주파수 오차, skew가 모두 정상 범위로 돌아왔고 `Update interval`이 길어진 것(chrony가 안정되면 폴링 간격을 늘린다)도 같은 방향이다. `Reference ID`는 `C0A80A6F`(web01)다. 시계 설정과 재부팅이 함께 일어났고 두 측정의 부팅 후 경과 시간도 달라서 시계가 원인이라고 분리해 증명한 것은 아니지만, 세 VM을 `tsc`로 바꾼 뒤의 결과다. `Stratum`이 9에서 4가 된 것은 web01이 8이 아니라 3으로 보이기 때문이다(db01의 `chronyc sources`, §6-10). web01이 왜 달라졌는지는 확인하지 않았다.

---

## 6. db01: Data Tier 구축

### 6-1. 추가 디스크 확인: v16, 디스크 문자를 믿지 말고 '크기'로 고른다

```bash
lsblk
```
> ⚠️ **디스크 문자(`sda`/`sdb`/…)는 VM마다, 부팅마다 바뀐다.** v15는 `sdb=20G, sdc=5G, sdd=5G`라고 적었지만 재현할 때의 db01은 `sda(20G)` / `sdb(5G)` / **`sdc(10G — OS 디스크, 파티션·마운트 있음)`** / `sdd(5G)`였다. 예전 값을 그대로 `pvcreate`에 넣었다면 OS 디스크를 대상으로 하는 명령이 됐을 것이다.

🖥️ db01에서 먼저 root가 된다. **변수는 이 root 셸 안에서만 유지되므로 §6-2까지 같은 창에서 이어서 한다**(변수를 만든 뒤에 `sudo -i`를 치면 사라진다):
```bash
sudo -i
```

**파티션이나 마운트가 전혀 없는 '빈 디스크'만 크기와 함께 나열하고, 크기로 변수에 자동 대입한다** (OS 디스크는 파티션이 있어 자동으로 빠진다. 20G는 pgdata, 5G 두 개는 각각 pgwal / pgbackup이며 5G 둘은 서로 바꿔도 무방하다):
```bash
SCAN=$(lsblk -dbpno NAME,SIZE,TYPE | awk '$3=="disk"{print $1, $2}' | while read d s; do
  [ "$(lsblk -n "$d" | wc -l)" -eq 1 ] && echo "$d  $((s/1024/1024/1024))G"
done)
echo "$SCAN"

PGDATA_DISK=$(echo "$SCAN" | awk '$2=="20G"{print $1}')
PGWAL_DISK=$(echo "$SCAN" | awk '$2=="5G"{print $1}' | sed -n 1p)
PGBACKUP_DISK=$(echo "$SCAN" | awk '$2=="5G"{print $1}' | sed -n 2p)
echo "pgdata=$PGDATA_DISK pgwal=$PGWAL_DISK pgbackup=$PGBACKUP_DISK"

if [ "$(echo "$SCAN" | awk '$2=="20G"' | wc -l)" -eq 1 ] && [ "$(echo "$SCAN" | awk '$2=="5G"' | wc -l)" -eq 2 ]; then echo "✅ 빈 디스크 20G 1개 + 5G 2개"; else echo "❌ 20G 1개 + 5G 2개가 아닙니다 — 위 목록을 보고 변수 세 개를 직접 지정하세요"; fi
```
재현할 때의 출력 예 (재부팅 뒤 db01. 이번에는 `sda`가 10G OS 디스크, 20G가 `sdb`였다. 스캔 부분의 출력은 실제 기록이고, 그 아래 두 줄은 이 블록을 스텁 `lsblk`로 시험한 결과라 실제 db01에서는 아직 미실행이다):
```
/dev/sdb  20G
/dev/sdc  5G
/dev/sdd  5G
pgdata=/dev/sdb pgwal=/dev/sdc pgbackup=/dev/sdd
✅ 빈 디스크 20G 1개 + 5G 2개
```
> 이전 버전은 `PGDATA_DISK=/dev/sdX` 같은 예시 글자를 손으로 바꾸게 했는데, 재현 기록에서 그대로 붙여넣어져 `echo`에 `pgdata=/dev/sdX pgwal=/dev/sdY pgbackup=/dev/sdZ`가 찍힌 채 넘어갈 뻔했다. `echo`에 `sdX`가 보이면 값이 안 바뀐 것이다. 참고로 LVM을 만든 뒤 이 블록을 다시 실행하면 그 디스크들은 '자식이 있는 디스크'라 목록에서 빠지고 ❌가 나오는 것이 정상이다.

### 6-2. lvm2 설치 후 LVM 구성: v3, lvm2 설치 단계 추가

**지금 막혀 있던 지점이다.** `pvcreate: command not found`가 나는 이유는 `lvm2` 패키지가 로컬 저장소에 없어서다. 아래 둘 중 하나로 해결한다.

**방법 A (권장, 폐쇄망 구조 유지)**: web01에서 §4-6의 `lvm2` 추가 다운로드를 먼저 실행한 뒤, db01에서:
```bash
dnf clean metadata
dnf repolist
dnf install -y lvm2
```

**방법 B (빠른 임시 해결, 이번만 온라인 저장소 사용)**: 지금 당장 막힌 걸 풀고 싶다면, baseos/appstream을 잠깐 켜서 설치하고 다시 끈다.
```bash
dnf config-manager --set-enabled baseos appstream
dnf install -y lvm2
dnf config-manager --set-disabled baseos appstream
```

설치 확인:
```bash
which pvcreate vgcreate lvcreate mkfs.xfs
```
`mkfs.xfs`를 못 찾겠다는 오류가 나면 `xfsprogs`도 같은 방식으로 추가 설치한다.

**LVM 구성** (설치 후 진행):
```bash
# 물리 볼륨(PV) 생성 — §6-1에서 정한 변수 사용 (디스크 문자를 직접 쓰지 않음)
pvcreate $PGDATA_DISK $PGWAL_DISK $PGBACKUP_DISK

# 역할별로 별도 볼륨그룹(VG) 생성
vgcreate vg_pgdata   $PGDATA_DISK
vgcreate vg_pgwal    $PGWAL_DISK
vgcreate vg_pgbackup $PGBACKUP_DISK

# 각 VG 전체 용량으로 논리볼륨(LV) 생성
lvcreate -l 100%FREE -n lv_pgdata   vg_pgdata
lvcreate -l 100%FREE -n lv_pgwal    vg_pgwal
lvcreate -l 100%FREE -n lv_pgbackup vg_pgbackup

# XFS로 포맷
mkfs.xfs /dev/vg_pgdata/lv_pgdata
mkfs.xfs /dev/vg_pgwal/lv_pgwal
mkfs.xfs /dev/vg_pgbackup/lv_pgbackup

# 마운트포인트 생성 및 마운트
mkdir -p /pgdata /pgwal /pgbackup
mount /dev/vg_pgdata/lv_pgdata     /pgdata
mount /dev/vg_pgwal/lv_pgwal       /pgwal
mount /dev/vg_pgbackup/lv_pgbackup /pgbackup

# 재부팅 후에도 자동 마운트되도록 fstab에 등록
cat >> /etc/fstab <<'EOF'
/dev/vg_pgdata/lv_pgdata     /pgdata    xfs  defaults  0 0
/dev/vg_pgwal/lv_pgwal       /pgwal     xfs  defaults  0 0
/dev/vg_pgbackup/lv_pgbackup /pgbackup  xfs  defaults  0 0
EOF

mount -a
df -hT | grep -E 'pgdata|pgwal|pgbackup'
```
재현 기록(db01): `dnf install -y lvm2`는 로컬 저장소에서 6개 패키지(3.9 MB)로 설치됐다(방법 A). `pvcreate` 출력에 `Creating devices file /etc/lvm/devices/system.devices`가 한 줄 더 나오는 것은 LVM이 디바이스 목록 파일을 처음 만들었다는 안내로, 오류가 아니다. `mount -a`는 아무것도 출력하지 않았고, `df -hT`는 `/pgdata` 20G, `/pgwal` 5.0G, `/pgbackup` 5.0G(모두 xfs)였다.

### 6-3. PostgreSQL 16 설치: v16, PGDG/15 대신 로컬 저장소의 16 사용

**이유(변경)**: 원래 이 가이드는 원본 구성도의 15를 맞추려고 PGDG(인터넷) 저장소를 쓰라고 했지만, 그러면 지금까지 만든 폐쇄망 구조와 모순되고 로컬 저장소의 16과 파일 충돌이 날 수 있다. §4-6에서 web01에 만든 로컬 저장소(`local-web01`)에 `postgresql-server`가 들어 있으므로 **16을 그대로 채택**한다. (이 가이드의 예전 기록에서는 db01에 이미 설치돼 있었지만(16.14), db01을 새로 만든 재현에서는 `not installed`였다. 그래서 확인 → 설치 순서로 쓴다. 이미 설치돼 있으면 `dnf install`은 `Nothing to do`로 끝난다.)

```bash
rpm -q postgresql-server
dnf install -y postgresql-server postgresql-contrib
postgres --version
```
재현 기록(db01): `rpm -q`는 `package postgresql-server is not installed`, `dnf install`은 `local-web01`에서 63개 패키지(다운로드 16 MB, 설치 63 MB, 대부분 perl 계열 의존성)를 설치했고, `postgres --version`은 `postgres (PostgreSQL) 16.15`였다. 외부 저장소 없이 통과했으므로 §4-6의 로컬 저장소에 필요한 패키지가 들어 있다는 것도 확인된 셈이다.

> **정리 (PGDG 저장소를 예전에 추가해 둔 경우에만)**: `dnf repolist`에 `local-web01` 한 줄만 나오면 지울 것이 없으니 아래는 **건너뛴다**(재현 기록 db01은 설치 전과 후 모두 `local-web01` 한 줄뿐이었다). 예전 버전 가이드로 PGDG 저장소(pgdg-common, pgdg14~18)를 추가해 뒀다면, 쓰이지도 않는데 `dnf repolist`에 계속 뜨면서 매번 인터넷으로 메타데이터를 확인하려다 실패하거나 지연될 수 있으니 정리해 두는 걸 권한다.

```bash
dnf repolist                          # local-web01 외에 pgdg가 보일 때만 아래를 실행
rm -f /etc/yum.repos.d/pgdg*.repo     # pgdg 파일이 없으면 아무 일도 일어나지 않습니다
dnf clean metadata
```

> (PGDG가 없는 이 PC에서는 실행해 본 기록이 없다.)

### 6-4. 데이터 디렉터리를 /pgdata로 지정해 초기화(initdb)

**이유**: 기본 데이터 경로(`/var/lib/pgsql/data`)는 OS 디스크에 있어 별도 볼륨의 이점이 없다. LVM으로 분리한 `/pgdata`를 실제 데이터 디렉터리로 사용하도록 지정한다.

> ⚠️ **v10 소급 수정**: `/pgwal`도 여기서 함께 `postgres` 소유로 바꿔둔다. 원래는 `/pgdata`만 chown하고 `/pgwal`은 `root:root`로 남아있었는데, 이러면 §6-7에서 켜는 `archive_mode`(WAL 아카이빙)가 postgres 계정으로 `/pgwal`에 쓰기를 시도할 때마다 `Permission denied`로 조용히 계속 실패한다(에러가 `pg_stat_archiver`에만 쌓이고 서비스 자체는 멀쩡해 보여서 눈치채기 어렵다). db02를 추가하며 페일오버 연습(§12-6)을 하다가 이 문제를 실제로 발견했다.

> ⚠️ **v16 소급 수정**: `/pgbackup`도 같은 이유로 여기서 함께 `postgres` 소유로 바꿔둔다(위 명령의 `chown` 끝에 추가). `/pgbackup`은 `mkdir`로 만들어진 그대로 `root:root 755`라서, 이대로 두면 §6-9의 백업 스크립트가 postgres 계정으로 `/pgbackup`에 덤프 파일을 쓰지 못하고 매일 밤 조용히 실패한다. 이 가이드의 db01은 실제로 그 상태로 약 1주일간 백업 파일이 0개였고(§15-6, §15-8), db02에서는 `touch` 테스트로 `Permission denied`를 바로 재현했다(§15-2). 이미 §6-4를 지난 상태라면 §6-9의 첫 줄(`chown postgres:postgres /pgbackup`)이 같은 일을 한다.

> v3에서 바뀐 점: 패키지가 버전 미표기(`postgresql`, PGDG의 `postgresql15`가 아님)라서 실행 파일이 `/usr/bin/`에 있고, systemd 서비스 이름도 `postgresql`이다(`postgresql-15`가 아님).

```bash
mkdir -p /pgdata/data
chown postgres:postgres /pgdata /pgdata/data /pgwal /pgbackup
chmod 700 /pgdata/data

sudo -u postgres /usr/bin/initdb -D /pgdata/data -E UTF8 --locale=C
```
재현 기록(db01): `fixing permissions on existing directory /pgdata/data ... ok`로 시작해 마지막에 `Success. You can now start the database server using:`가 나왔다. 그 사이의 `initdb: warning: enabling "trust" authentication for local connections`는 오류가 아니라 안내다. 로컬 소켓과 `127.0.0.1`/`::1` 접속에 비밀번호를 묻지 않게 초기화됐다는 뜻으로, 이 랩에서는 `sudo -u postgres psql`이 바로 되는 것이 이 덕분이다. 운영이라면 `initdb`에 `--auth-local=peer --auth-host=scram-sha-256`을 주는 것이 일반적이지만, 이 PC에서 그렇게 해 본 기록이 없고 이후 장(복제, HA)이 지금 상태를 전제로 하는지도 확인하지 않아 여기서는 바꾸지 않는다.

systemd 서비스가 이 경로를 쓰도록 override 설정:
```bash
mkdir -p /etc/systemd/system/postgresql.service.d
cat > /etc/systemd/system/postgresql.service.d/override.conf <<'EOF'
[Service]
Environment=PGDATA=/pgdata/data
EOF
systemctl daemon-reload
```

### 6-5. SELinux 컨텍스트 지정

```bash
semanage fcontext -a -t postgresql_db_t "/pgdata(/.*)?"
semanage fcontext -a -t postgresql_db_t "/pgwal(/.*)?"
semanage fcontext -a -t postgresql_db_t "/pgbackup(/.*)?"
restorecon -R /pgdata /pgwal /pgbackup
ls -Zd /pgdata /pgdata/data /pgwal /pgbackup
```
v16: `restorecon -Rv`의 `-v`를 뺐다. `-v`는 라벨을 바꾼 파일을 한 줄씩 전부 출력하는데, §6-4의 `initdb`가 이미 파일을 수백 개 만든 뒤라 재현 기록에서 화면이 수백 줄로 넘쳤다(전부 `unlabeled_t` → `postgresql_db_t`, 내용은 같은 줄의 반복). `-v` 없이는 성공하면 아무것도 출력하지 않는다. 대신 `ls -Zd`로 네 디렉터리가 모두 `postgresql_db_t`인지 본다(이 명령의 출력은 이 PC에서 아직 확인하지 않았다. `-Rv` 출력에서는 `/pgdata`, `/pgwal`, `/pgbackup`이 `system_u:object_r:postgresql_db_t:s0`, `/pgdata/data`가 `unconfined_u:object_r:postgresql_db_t:s0`로 바뀐 것을 확인했다).

### 6-6. PostgreSQL 기동

```bash
systemctl enable --now postgresql
systemctl status postgresql --no-pager
```

### 6-7. postgresql.conf / pg_hba.conf 설정

```bash
vim /pgdata/data/postgresql.conf
```
아래 값 수정/추가:
```
listen_addresses = 'localhost,10.10.10.13'
port = 5432

# WAL 아카이빙 (별도 볼륨인 /pgwal에 저장 → 향후 복제/PITR 대비)
wal_level = replica
archive_mode = on
archive_command = 'cp %p /pgwal/%f'
```

```bash
vim /pgdata/data/pg_hba.conf
```
맨 아래에 was01(서비스망 IP)만 허용하는 줄 추가:
```
# TYPE  DATABASE  USER  ADDRESS          METHOD
host    all       all   10.10.10.12/32   scram-sha-256
```

```bash
systemctl restart postgresql
```

**반드시 아래로 실제 적용됐는지 확인한다**: `postgresql.conf`를 고쳤는데도 재시작 후 `listen_addresses` 변경이 반영되지 않아(로컬만 리스닝) was01에서 "No route to host"로 접속이 거부된 사례가 실제로 있었다.
```bash
ss -tnlp | grep 5432
```
`127.0.0.1:5432`, `[::1]:5432`만 보이고 `10.10.10.13:5432`가 안 보이면 아직 적용 안 된 것이다. 아래를 확인한다.
```bash
# 실제 실행 중인 설정에 반영됐는지 postgres에게 직접 물어보기
sudo -u postgres psql -c "SHOW listen_addresses;"
grep -n "^listen_addresses" /pgdata/data/postgresql.conf
```
재현 기록(db01): `ss`에 `127.0.0.1:5432`, `10.10.10.13:5432`, `[::1]:5432` 세 줄, `SHOW listen_addresses`는 `localhost,10.10.10.13`, `grep`은 `60:listen_addresses = 'localhost,10.10.10.13'`이었다. `pg_hba.conf` 끝 두 줄은 위 헤더 주석과 `host all all 10.10.10.12/32 scram-sha-256`이었다. 또 재시작 뒤 `systemctl status postgresql`의 프로세스 목록에 `postgres: archiver`가 새로 생겼는데(§6-6 첫 기동에는 없었다), `archive_mode = on`이 반영됐다는 신호다.
- `SHOW listen_addresses`가 `localhost`만 나오면 파일 저장이 안 됐거나(vim에서 `:wq` 대신 `:q`로 종료 등), 줄 앞에 `#`이 남아있는 경우다. 다시 `vim /pgdata/data/postgresql.conf`로 열어 `listen_addresses = 'localhost,10.10.10.13'` 줄이 주석 없이 실제로 저장돼 있는지 확인한 후 `systemctl restart postgresql`을 다시 실행한다.
- **`SHOW listen_addresses`가 이미 `localhost,10.10.10.13`로 정확히 나오는데도 `ss -tnlp`에 `10.10.10.13:5432`가 안 뜨면, 설정 문제가 아니라 §3-5의 bond0 IP 문제일 가능성이 매우 높다.** 실제로 이 순서로 원인을 찾았다: `postgres` 로그(`/pgdata/data/log/` 안의 최신 파일)에 `could not bind IPv4 address "10.10.10.13": Cannot assign requested address`가 있는지 확인한다. 있다면 db01의 bond0에 10.10.10.13 자체가 안 잡혀 있는 것이니 **§3-5로 가서 `ip a show bond0`부터 다시 확인**하고, 고친 뒤 `systemctl restart postgresql`을 다시 실행한다(IP가 나중에 생겨도 postgres가 자동으로 재시도하진 않는다).
- 파일도 맞고 bond0 IP도 맞는데 안 되면 `systemctl status postgresql -l`로 재시작이 실제로 성공했는지(설정 오류로 재시작 실패 후 이전 프로세스가 그대로 떠 있는 경우가 있다) 확인한다.

### 6-8. 애플리케이션용 계정/DB 생성

> ⚠️ **v16: 비밀번호를 파일에 적지 않고, 실행할 때 묻도록 바꿨다.** 예전 블록은 `'여기에_직접_정한_비밀번호_입력'`을 손으로 바꿔서 실행하게 했는데, 안 바꾸고 그대로 실행해도 SQL로는 아무 오류가 없어 "그 문구 자체"가 진짜 비밀번호로 등록된다. 이 가이드에서 이미 한 번 인증 실패로 이어졌고, 재현 기록에서도 경고를 읽고도 그대로 실행되어 `CREATE ROLE`이 나왔다. 아래 블록은 실행하면 비밀번호를 묻는다(입력은 화면에 안 보인다). **§5-6-5의 `application.properties`에 적은 값과 정확히 같아야 하고**, 영문과 숫자만 허용한다(그 밖의 문자가 있거나 비어 있으면 만들지 않고 ❌를 출력한다).

```bash
read -rsp "app_user 비밀번호(영문·숫자만, application.properties와 동일): " APP_PW; echo
if [[ "$APP_PW" =~ ^[A-Za-z0-9]+$ ]]; then
sudo -u postgres psql <<EOF
CREATE USER app_user WITH PASSWORD '${APP_PW}';
CREATE DATABASE appdb OWNER app_user;
EOF
else
  echo "❌ 영문·숫자 이외의 문자가 있거나 비어 있어서 만들지 않았습니다"
fi
unset APP_PW
```
정상이면 `CREATE ROLE`, `CREATE DATABASE` 두 줄이 나온다. (이 블록은 `psql` 자리에 `cat`을 넣은 스텁으로 입력 검사만 시험했고, 실제 db01에서 그대로 실행해 본 기록은 없다.)

**이미 자리표시자로 만들어 버렸다면**: 같은 명령을 다시 실행하면 `ERROR: role "app_user" already exists`, `ERROR: database "appdb" already exists`가 나온다(재현 기록). 새로 만들 필요 없이 아래 `ALTER USER`만 하면 된다. 재현 기록에서는 이렇게 고쳤고 `ALTER ROLE`이 나왔다.

**이미 만든 계정의 비밀번호를 나중에 바꿔야 한다면** (예: 위 실수를 했거나 잊어버렸을 때) 새로 만들 필요 없이 아래로 바로 변경할 수 있다:
```bash
sudo -u postgres psql -c "ALTER USER app_user WITH PASSWORD '새로운_비밀번호';"
```

### 6-9. pg_dump 백업 스크립트 + cron 등록

> ⚠️ **v16: 첫 줄 `chown postgres:postgres /pgbackup`이 없으면 이 백업은 매일 밤 조용히 실패한다.** `/pgbackup`이 `root:root`이면 postgres 계정이 덤프 파일을 만들 수 없는데, cron은 실패해도 화면에 아무것도 안 보여준다(§15-6, §15-8: 이 db01에서 실제로 약 1주일간 `backup_*.dump`가 0개였음). §6-4에서 이미 했다면 그대로 통과한다. 또 아래 마지막의 **즉시 실행 확인**을 꼭 한다. cron은 새벽 2시까지 기다려야 결과가 보인다.

```bash
chown postgres:postgres /pgbackup

cat > /pgbackup/pg_backup.sh <<'EOF'
#!/bin/bash
BACKUP_DIR=/pgbackup
DATE=$(date +%Y%m%d_%H%M%S)
/usr/bin/pg_dump -U postgres -F c -f "${BACKUP_DIR}/backup_${DATE}.dump" appdb
# 7일 지난 백업 파일 자동 삭제
find "${BACKUP_DIR}" -name "backup_*.dump" -mtime +7 -delete
EOF

chown postgres:postgres /pgbackup/pg_backup.sh
chmod 700 /pgbackup/pg_backup.sh

(sudo -u postgres crontab -l 2>/dev/null; echo "0 2 * * * /pgbackup/pg_backup.sh") | sudo -u postgres crontab -
sudo -u postgres crontab -l
```

**즉시 실행 확인** (v16 추가):
```bash
ls -ldZ /pgbackup                        # postgres postgres 소유여야 함
cd /tmp                                  # /root에서 실행하면 exit=1이 나옴(아래 설명)
sudo -u postgres /pgbackup/pg_backup.sh; echo "exit=$?"
ls -l /pgbackup
systemctl is-active crond
```
통과 기준: `exit=0`, `/pgbackup`에 `backup_YYYYMMDD_HHMMSS.dump`가 1개, `crond`가 `active`이다. `Permission denied`로 덤프 파일이 안 생기면 위 `chown`을 빠뜨린 것이다.

재현 기록(db01): `chown` 뒤 `/pgbackup`은 `drwxr-xr-x postgres postgres … postgresql_db_t`, 덤프 파일 `backup_20260930_153216.dump`(800바이트, appdb에 테이블이 아직 없어 작음)가 생겼고 `crond`는 `active`였다. 다만 `/root`에서 실행했을 때는 `find: Failed to restore initial working directory: /root: Permission denied`와 `exit=1`이 함께 나왔다. 스크립트 문제가 아니라 실행 위치 때문이다. `sudo -u postgres`는 현재 디렉터리(`/root`, 권한 700)를 그대로 물려받는데 postgres는 그곳으로 돌아갈 수 없어서, 스크립트의 마지막 명령인 `find`가 실패하고 그 종료 코드가 스크립트의 종료 코드가 된다. 그래서 위 블록에 `cd /tmp`를 넣었다(`cd /tmp` 후 다시 실행하니 `exit=0`이 나왔다). cron은 작업을 해당 계정의 홈 디렉터리에서 실행하므로 이 문제가 없을 것으로 보이지만, 새벽 2시에 실제로 도는지는 미확인이다(다음 날 `ls -l /pgbackup`). 덤프 파일이 `-rw-r--r--`(누구나 읽기)로 만들어지는 점도 있다. 민감한 데이터가 생기면 스크립트 앞에 `umask 077`을 넣는 것을 검토한다(이 PC에서 시험하지 않음). 참고로 db01이 §13 이후 Standby가 되면 이 cron은 §15-8에서 폐기한다.

### 6-10. NTP 클라이언트 설정

```bash
dnf install -y chrony
vim /etc/chrony.conf
```
기존 `pool` 라인은 지우고 추가:
```
server web01 iburst
```
```bash
systemctl enable --now chronyd
systemctl restart chronyd
chronyc sources
```
재현 기록(db01): 재시작 직후의 `chronyc sources`는 `^? web01  3  6  3  1  +5523us[+5523us] +/- 9726us`였다. `^?`(아직 선택 전)와 `Reach 3`은 재시작 직후에는 정상이고, 1~2분 뒤 다시 실행해 `^* web01`과 늘어난 `Reach`가 나오는지 본다(재현 기록: 약 10분 뒤 `^* web01  3  6  377  7  +10us[  +23us] +/-  11ms`로 바뀌어 동기화가 확인됐다). `systemctl status chronyd`의 로그에는 기동 4초 뒤 `Selected source`(web01)가 찍혔고, 이때 web01의 `Stratum`은 3으로 보였다.

### 6-11. 방화벽: PostgreSQL 포트는 was01에서만 허용

```bash
firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="10.10.10.12/32" port protocol="tcp" port="5432" accept'
firewall-cmd --reload
firewall-cmd --list-rich-rules
```
재현 기록(db01): `--add-rich-rule`, `--reload`는 `success`, `--list-rich-rules`는 `rule family="ipv4" source address="10.10.10.12/32" port port="5432" protocol="tcp" accept`였다(입력과 달리 `port port=…`로 표시되는 것은 firewalld의 출력 형식일 뿐 정상).

**동작 확인: 5432가 was01에서만 열렸는지** (v16 추가):

🖥️ **was01**에서 (열려 있어야 함):
```bash
timeout 3 bash -c '</dev/tcp/10.10.10.13/5432' && echo OPEN || echo BLOCKED
```
🖥️ **web01**에서 (막혀 있어야 함):
```bash
timeout 3 bash -c '</dev/tcp/10.10.10.13/5432' && echo OPEN || echo BLOCKED
```
was01은 `OPEN`, web01은 `BLOCKED`(`No route to host`)가 정상이다. §5-5의 8009 시험과 같은 원리이고, `No route to host`는 거부(reject)라서 나오는 메시지다. was01 쪽은 §7-2의 `psql`이 다시 확인한다. 재현 기록: was01은 `OPEN`, web01은 `bash: connect: No route to host` 뒤 `BLOCKED`였다.

> **`listen_addresses`를 위 §6-7에서 확인했는데도 was01에서 여전히 "No route to host"가 나온다면** bond0이 속한 zone이 rich-rule을 넣은 `public`이 맞는지 확인한다.

```bash
firewall-cmd --get-zone-of-interface=bond0
firewall-cmd --zone=public --list-all
```

> `bond0`이 `public`이 아닌 다른 zone(`default` 등)에 속해 있으면 rich-rule이 적용되지 않는다. 아래로 zone을 맞춘다.

```bash
firewall-cmd --permanent --zone=public --change-interface=bond0
firewall-cmd --reload
```

> 재현 기록(db01)에서는 `bond0`이 이미 `public`이라(`--list-all`의 interfaces가 `bond0 enp0s10 enp0s3 enp0s8 enp0s9` 전부 public) 이 명령은 `The interface is under control of NetworkManager, setting zone to 'public'.`만 출력하고 바뀐 것이 없었다. `bond0`이 이미 `public`이면 실행할 필요가 없다.

### 6-12. 커널 파라미터 튜닝 (DB 역할)

```bash
cat > /etc/sysctl.d/99-db-tuning.conf <<'EOF'
kernel.shmmax = 4294967296
kernel.shmall = 1048576
vm.swappiness = 10
vm.overcommit_memory = 2
EOF
sysctl --system
```
재현 기록(db01): `sysctl --system` 끝에 네 값(`kernel.shmmax = 4294967296`, `kernel.shmall = 1048576`, `vm.swappiness = 10`, `vm.overcommit_memory = 2`)이 그대로 적용됐다고 출력됐다.

> ⚠️ **`vm.overcommit_memory = 2`(strict)는 스왑이 0이면 커밋 한도(`CommitLimit`)가 RAM의 절반 정도로 줄어든다.** PostgreSQL 자체는 이 장에서 문제없이 뜨지만, Phase 2의 §16-3 문제 ②에서 db01의 `pcsd`가 정확히 이것 때문에 기동 타임아웃(`MemoryError`)을 겪었다(스왑 2 GB를 켜서 해결). 지금 상태를 미리 보려면 아래를 실행한다. 재현 기록(db01): `MemTotal` 2521312 kB(약 2.4 GiB), `SwapTotal` 0, `CommitLimit` 1260656 kB(약 1.2 GiB, RAM의 정확히 절반), `Committed_AS` 566056 kB(약 550 MiB)였다. PostgreSQL만 있는 지금은 여유가 있지만, 스왑이 0이라는 조건이 §16-3과 같다.

```bash
grep -E 'MemTotal|SwapTotal|CommitLimit|Committed_AS' /proc/meminfo
```

### 6-13. 최종 확인

```bash
systemctl status postgresql chronyd --no-pager
cat /proc/net/bonding/bond0
sudo -u postgres psql -c "\l"
ss -tnlp | grep 5432
```
재현 기록(db01): 두 서비스 모두 `active (running)`, bond0은 `fault-tolerance (active-backup)`에 슬레이브 `enp0s10`, `enp0s9`가 둘 다 `MII Status: up`(활성 슬레이브 `enp0s10`), `\l`에는 `appdb | app_user | UTF8 | libc | C | C`, `ss`에는 `127.0.0.1`, `10.10.10.13`, `[::1]` 세 줄이 나왔다.

**WAL 아카이브가 실제로 되는지** (v16 추가, 같은 확인을 §12-6에서 db02로도 했다):
```bash
sudo -u postgres psql -c "SELECT pg_switch_wal();"
sleep 3
sudo -u postgres psql -xc "SELECT archived_count, last_archived_wal, failed_count FROM pg_stat_archiver;"
ls -l /pgwal
```
`archived_count`가 1 이상이고 `failed_count`가 0, `/pgwal`에 16 MB짜리 WAL 파일이 생기면 통과다. `failed_count`가 계속 오르면 §6-4의 `/pgwal` 소유권을 다시 본다. `postgres: archiver` 프로세스가 떠 있는 것만으로는 성공을 뜻하지 않는다. 재현 기록(db01): `archived_count` 1, `last_archived_wal` `000000010000000000000001`, `failed_count` 0, `/pgwal`에 16777216바이트 파일 1개(`postgres:postgres`, `-rw-------`)가 생겼다.

**(참고) 정확히 PostgreSQL 15가 꼭 필요한 경우**: 위에서 설명한 대로 권장하지 않지만, 굳이 15를 써야 한다면 먼저 `dnf remove postgresql postgresql-server postgresql-contrib`로 16을 완전히 제거한 뒤(파일 충돌 방지), PGDG 저장소를 추가해 `postgresql15-server`를 설치해야 한다. 이 경로는 인터넷 접속이 계속 필요해 폐쇄망 구성 취지와 어긋난다는 점을 감안한다.

---

