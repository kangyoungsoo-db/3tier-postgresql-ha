> 이 문서는 `3tier-rocky10-guide-v16.md` 의 1625~1939줄을 그대로 옮긴 것이다. 비밀번호와 로컬 경로만 자리표시자로 바꿨다.

## 7. 전체 연동 테스트 (End-to-End)

트래픽 흐름: `사용자 → Apache(web01:80) → AJP → Tomcat(was01:8009) → JDBC → PostgreSQL(db01:5432)`

**1) db01에서 직접 확인**
```bash
sudo -u postgres psql -d appdb -c "SELECT version();"
```

**2) was01에서 db01로 직접 접속 테스트**
```bash
dnf install -y postgresql
psql -h 10.10.10.13 -U app_user -d appdb -c "SELECT 1;"
```
비밀번호 입력 프롬프트가 뜨고 정상 조회되면 was01→db01 구간은 통과입니다. 재현 기록(was01): `dnf install -y postgresql`은 `local-web01`에서 `postgresql-16.15`와 `postgresql-private-libs` 2개 패키지(2.0 MB)를 설치했고, `psql -h 10.10.10.13 -U app_user -d appdb -c "SELECT 1;"`은 비밀번호 입력 뒤 `?column?` / `1` / `(1 row)`를 출력했습니다.

**3) was01에서 Tomcat 앱 직접 확인**
```bash
curl http://localhost:8080/app/db-check
```
정상이면 `DB 연결 성공: appdb`가 나옵니다. 이 응답 끝에는 줄바꿈이 없어서 프롬프트가 같은 줄에 붙어 `DB 연결 성공: appdb[root@was01 ~]#`처럼 보이는데 오류가 아닙니다. 이것으로 WAR 안의 `spring.datasource.password`가 §6-8에서 만든 `app_user` 비밀번호와 같다는 것도 함께 확인됩니다.

재현 기록(was01): §6-1~§6-13과 §7-2를 마친 뒤 처음 실행한 `curl`은 출력이 비어 있었고, 바로 다시 실행하자 `DB 연결 성공: appdb`가 나왔습니다. 첫 번째 출력이 비었던 원인은 **확인하지 못했습니다**. 이후 `curl -si http://localhost:8080/app/db-check | head`를 3회 연속 실행했을 때는 매번 `HTTP/1.1 200`, `Content-Type: text/plain;charset=UTF-8`, `Content-Length: 23`(본문 끝 줄바꿈 없음)이었습니다. 다시 비어 있으면 같은 명령으로 상태 줄과 본문을 함께 보세요.

**4) web01에서 AJP 프록시 경유 확인**
```bash
curl http://localhost/app/db-check
```

**5) 외부(호스트 PC)에서 확인**
```powershell
curl.exe http://192.168.10.111/app/db-check
```
> ⚠️ Windows PowerShell에서 그냥 `curl`을 치면 실제로는 `Invoke-WebRequest`의 별칭이라, 200이 아닌 응답(예: 아직 404일 때)에서 실제 원인과 무관하게 빨간 예외를 던집니다(버그 아님). 리눅스와 똑같이 결과만 보고 싶으면 `curl.exe`처럼 확장자를 붙이거나, 그냥 브라우저 주소창에 URL을 입력해서 확인하세요.

**이 5단계가 실제로 전부 통과했습니다** ✅ (db01 로컬 조회 → was01→db01 직접 psql → was01 Tomcat 직접 curl → web01 AJP 프록시 curl → 호스트 PC 외부 curl, 전부 `DB 연결 성공: appdb` 확인). 막히는 단계가 있다면: 2번에서 막히면 §3-5(bond0 IP)와 §6-7(listen_addresses)을, 3번에서 막히면 §5-6(빌드/배포)을, 4번에서 막히면 §4-2/§5-3(AJP)을 다시 보시면 됩니다.

재현 기록(3대를 새로 만든 수동 재현): 4)는 web01에서 `curl http://localhost/app/db-check`, 5)는 호스트 PC PowerShell에서 `curl.exe http://192.168.10.111/app/db-check`를 실행해 둘 다 `DB 연결 성공: appdb`가 나왔습니다. 1)~3)과 함께 5단계가 전부 통과했습니다.

---

## 8. 트러블슈팅 체크리스트

| 증상 | 확인 사항 |
|---|---|
1. bond0이 안 올라오거나 Link Down
-> `nmcli device status`로 실제 인터페이스명 재확인, Vagrantfile의 intnet 이름(`svc-net`)이 3대 모두 동일한지 확인 |

2. `nmcli con add ... master bond0`에서 `Warning: There is another connection with the name 'bond0'`
-> 이전에 이미 만든 적이 있다는 뜻(재부팅/재프로비저닝 등). 새로 만들지 말고 `nmcli con show bond0`, `ip a show bond0`로 기존 상태부터 확인 |

3. `dnf install <패키지>`에서 `No match for argument` (was01/db01)
-> baseos/appstream이 꺼진 상태에서 그 패키지가 web01 로컬 저장소 다운로드 목록(§4-6)에 없는 것. web01에서 추가 다운로드 후 `createrepo_c --update`, 클라이언트에서 `dnf clean metadata` |

4. db01 `pvcreate: command not found`
-> `lvm2` 미설치 — §6-2 참고 |

5. Tomcat 설정을 고쳤는데 반영이 안 됨
-> `systemctl show tomcat -p Environment`로 실제 `CATALINA_BASE` 확인 후 그 경로의 `conf/server.xml`을 수정했는지 확인 (`/opt/tomcat`이 아니라 RPM 설치는 `/usr/share/tomcat`) |

6. AJP(8009)가 안 뜸
-> `ss -tnlp \| grep 8009`로 먼저 확인 → 안 뜨면 위 항목처럼 잘못된 server.xml을 고쳤을 가능성. 뜨는데도 502면 SELinux(`httpd_can_network_connect`)나 방화벽 rich-rule의 source IP 확인 |

7. WAR 배포는 되는데 앱이 이상하게 동작
-> `pom.xml`의 Spring Boot 버전과 Tomcat 버전 궁합 확인 (Spring Boot 3.x/4.x=Jakarta EE→Tomcat10.1+ 필요, Tomcat9=javax EE→Spring Boot 2.7.x) — §5-6 참고 |

8. `/app/db-check` 요청 시 404
-> 컨트롤러 `@GetMapping`에 `/app`을 중복으로 붙이지 않았는지 확인(§5-6 참고, WAR 파일명이 이미 컨텍스트 경로를 결정함) |

9. web01→was01 AJP 502/타임아웃
-> ① `setsebool -P httpd_can_network_connect 1` 적용 여부
->② was01 방화벽 rich-rule의 source IP가 web01 서비스망 IP(10.10.10.11)인지
->③ AJP Connector가 실제로 주석 해제됐는지 |

10. was01→db01 JDBC/psql 연결 시 "No route to host"
-> db01에서 `ss -tnlp \| grep 5432`로 `10.10.10.13:5432`가 실제 리스닝 중인지 먼저 확인(§6-7 — 설정 파일을 고쳐도 반영이 안 되는 경우가 실제로 있었습니다). 리스닝 중인데도 안 되면 bond0의 firewalld zone이 `public`인지 확인(§6-11) |

11. was01→db01 JDBC 연결 거부(Connection refused)
-> ① db01 `pg_hba.conf`에 was01 서비스IP(10.10.10.12/32) 라인
-> ② db01 방화벽 rich-rule |

12. postgresql 서비스 시작 실패
-> `journalctl -u postgresql -n 50 --no-pager` 확인. 대부분 SELinux 컨텍스트(`restorecon`) 또는 `/pgdata` 소유권(`chown postgres:postgres`) 문제 |

13. SELinux가 뭔가를 막고 있는지 의심될 때
-> `ausearch -m avc -ts recent` → 필요시 `audit2allow -a`로 정책 제안 확인 |

14. dnf 설치 중 x86-64-v3 관련 커널 패닉/부팅 실패
-> 호스트 CPU가 x86-64-v3(AVX2 등)를 지원하는지 확인. 오래된 CPU라면 Rocky 10 대신 9로 진행 |

15. `ip a show bond0`에 다른 서버의 IP가 보임 / 두 서버가 같은 IP를 씀
-> bond0 만들 때 다른 서버 창 명령어를 복사하다 IP를 안 바꾼 것. §3-5의 확인 블록(`✅/❌`)으로 대조. v16부터는 §3-5 블록이 호스트명으로 IP를 스스로 고르므로 **같은 블록을 그대로 다시 실행**하면 정정됨(`nmcli con add`부터 손으로 다시 치면 중복 프로파일 생성) |

16. postgres 로그에 `could not bind IPv4 address ...: Cannot assign requested address`
-> `listen_addresses` 설정 문제가 아니라 bond0에 그 IP 자체가 없는 것. §3-5 참고, IP 고친 뒤 `systemctl restart postgresql` 다시 실행 |

17. `psql`/앱 연결 시 `password authentication failed`
-> `CREATE USER`에서 자리표시자 문구를 안 바꾸고 그대로 실행했을 가능성. `sudo -u postgres psql -c "ALTER USER app_user WITH PASSWORD '새값';"`로 재설정(§6-8) 후 `application.properties`도 같이 수정 |

18. 개발 PC에서 `mvn`이 인식 안 됨
-> `mvnw.cmd`(Maven Wrapper)가 프로젝트에 있는지 먼저 확인, 없으면 Maven 수동 설치(§5-6-1) |

19. pom.xml 수정 후 `Non-parseable POM ... Expected root element 'project' but found ...`
-> `<parent>` 등 일부 조각만 붙여넣다 `<project>` 감싸는 태그까지 지워진 것. §5-6-2의 pom.xml 전체를 통째로 교체 |

20. `mvn package`가 로컬에서 테스트 실패로 멈춤(`Failed to configure a DataSource`)
-> 테스트가 db01(10.10.10.13)에 접속을 시도하는데 호스트 PC에서는 그 내부망에 닿지 않아 항상 실패함. `-DskipTests` 사용(§5-6-6) |

21. was01에서 `curl -o /var/lib/tomcat/webapps/app.war ...`가 `Permission denied`
-> `vagrant ssh`는 `root`가 아닌 `vagrant` 계정. 명령 앞에 `sudo` 필요(§5-6-7). 다운로드가 중간에 끊기면 개발 PC의 `python -m http.server`가 `ConnectionResetError`를 내는 것처럼 보이지만 원인은 was01 쪽 권한 문제 |

22. war 안 파일 확인 시 `unzip: command not found`
-> Rocky 최소 설치엔 기본 미포함. §3-4에 `unzip`을 공통 패키지에 추가해뒀음(아직 인터넷 되는 시점에 설치됨). 이미 폐쇄망으로 전환됐다면 `java-21-openjdk-devel`을 추가해 `jar tf`로 대체 |

23. Windows PowerShell에서 `curl http://...` 결과가 이상한 빨간 에러로 나옴
-> PowerShell의 `curl`은 `Invoke-WebRequest` 별칭이라 비-200 응답에 예외를 던짐(버그 아님). `curl.exe`를 쓰거나 브라우저로 확인(§7) |

24. `dnf install <패키지>`가 "Nothing to do"로 끝나는데 정작 다른 서버에선 그 패키지를 못 찾음(§9)
-> 그 패키지가 지금 실행한 서버에 이미 설치돼 있는지 확인(`rpm -q <패키지>`). 이미 설치돼 있으면 `--downloadonly`가 실제로는 다운로드를 안 함 — 아직 설치 안 된 서버(예: 새로 만든 web02)에서 받아야 함 |

25. pacemaker/corosync/pcs/resource-agents가 `No match for argument`로 계속 안 잡힘
-> `dnf repolist all \| grep -i high`로 `highavailability` 저장소가 비활성화 상태인지 확인 → `dnf config-manager --set-enabled highavailability`. 외부 저장소를 끈 노드(was01/was02처럼 `local-web01`만 쓰는 노드)에서는 로컬 저장소에 rpm이 채워져 있고 `dnf clean metadata`를 했는지 확인(§9-3 8번) |

26. 로컬 저장소의 rpm 파일이 `curl -I`에서 403 Forbidden(404 아님)
-> `ls -Z <파일>`로 SELinux 컨텍스트 확인, `httpd_sys_content_t`가 아니면 `restorecon -Rv /repo/rocky10/local/`. 특히 `mv`로 파일을 옮긴 직후 자주 발생 |

27. `pcs host auth`에서 `Could not resolve host`
-> 호스트 이름 대신 `addr=<IP>`를 명시하거나 먼저 `/etc/hosts`에 등록 |

28. `pcs host auth`에서 `port 2224 ... Could not connect to server`
-> `sudo firewall-cmd --add-service=high-availability --permanent && --reload`를 해당 노드에서 실행했는지 확인 |

29. `pcs status`에서 방금 추가한 노드가 계속 `UNCLEAN (offline)`
-> ① `ping`으로 서비스망(bond0) 통신부터 확인
-> ② `ip -4 addr show bond0`로 그 노드에 bond0이 아예 없는 건 아닌지 확인(새 VM은 §9-2를 안 하면 bond0 자체가 없음)
-> ③ 문제없으면 `corosync-cfgtool -s`, `journalctl -u corosync`로 링 상태 확인 |

30. `pcs status`에 `Configuration invalid`, STONITH 관련 error/warning
-> 실습 환경이라 실제 펜싱 장치가 없어서 뜨는 정상적인 경고. `pcs property set stonith-enabled=false`로 해결(운영 환경에선 절대 이렇게 하면 안 됨) |

31. `sudo cat > 파일 <<EOF`가 Permission denied
-> `>` 리다이렉션은 sudo 적용 전에 현재 셸이 먼저 처리함(권한 상승 안 됨). `sudo tee 파일 <<EOF ... EOF`로 대체 |

32. `mod_ssl` 설치 후 `apachectl configtest`가 `SSLCertificateFile ... does not exist`로 실패
-> 자체서명 인증서 미생성. HTTPS를 안 쓰는 랩 환경이면 `mv /etc/httpd/conf.d/ssl.conf{,.disabled}`로 비활성화 |

33. AJP 프록시가 503, 에러 로그에 `(111)Connection refused ... <VIP>:8009`
-> Tomcat AJP Connector가 특정 고정 IP에만 `address=`로 바인딩돼 있어 VIP 주소로는 응답X. 방화벽으로 접근 제어를 이미 하고 있다면 `address="0.0.0.0"`으로 변경 |

34. Tomcat 설치 후 8080은 뜨는데 8009(AJP)만 안 뜸
-> AJP Connector에 `secretRequired="false"`가 빠지면 Ghostcat 대응으로 조용히 초기화 실패. `journalctl -u tomcat`에서 secret/AJP 관련 예외 확인 후 속성 추가 |

35. `python3 -m http.server <포트>`가 `Address already in use`
-> 그 포트를 이미 다른 서비스(예: Tomcat 8080)가 쓰고 있는 것. 안 쓰는 다른 포트로 변경 |

36. 새 서버에서 `wget: command not found`
-> Rocky 최소 이미지엔 기본 미포함. `curl -O <URL>`로 대체 |

37. `pcs cluster stop <자기자신>` 실행 후 같은 노드에서 `pcs status`/`curl`이 실패
-> 정상 동작. 방금 클러스터를 내린 노드는 자기 자신 상태를 조회할 대상이 없음 — 확인은 항상 살아있는 반대쪽 노드에서 |

38. 페일오버 시 VIP/서비스가 예상한 노드로 안 넘어가고 `Stopped`로 남음
-> `pcs status`의 `Failed Resource Actions`에 과거 실패 기록이 남아있으면 그 노드가 영구 제외됨. `pcs resource cleanup <리소스명>`으로 기록 삭제 후 재평가 |
39. `pg_basebackup`(또는 다른 명령)에 `VAR=값 sudo ...` 순서로 환경변수를 주면 명령 안에서 안 잡힘
-> `sudo`는 기본적으로 대부분의 환경변수를 제거함. `sudo -u <계정> env VAR=값 명령...`처럼 `env`로 감싸 `sudo` 뒤에 둬야 함 |

40. Standby로 쓸 서버에 PostgreSQL을 설치했는데 Primary와 패키지 출처/빌드가 다를 위험이 있음
-> 복제는 동일 빌드여야 안전함. `rpm -q postgresql-server`로 Primary의 정확한 빌드부터 확인하고, Standby도 같은 저장소·같은 방식으로 설치 |

41. Standby(pg_basebackup으로 만든 서버)의 PostgreSQL 로그에 `could not bind IPv4 address "<Primary IP>"` 경고
->`pg_basebackup`이 Primary의 `postgresql.conf`를 그대로 복사해오면서 `listen_addresses`에 Primary 자신의 IP가 남아있는 것. Standby 자신의 IP로 수정 후 재시작(복제 연결 자체엔 지장 없지만 Standby가 직접 트래픽을 받으려면 필수) |

42. `nmcli con up bond0-port1`에서 `Error: Connection activation failed: A dependency of the connection failed`
-> 치명적이지 않은 순서 문제(v16 업데이트 3번, Phase 1의 web01·was01·db01 전부에서 재현). 이어서 `nmcli con up bond0-port2` → `nmcli con up bond0` → `nmcli con up bond0-port1`을 실행하고 `cat /proc/net/bonding/bond0`에서 슬레이브 2개가 다 `MII Status: up`이면 정상. §3-5 블록이 이 순서를 자동 처리 |

43. 새 노드→기존 노드 ping만 `Destination Host Unreachable`이고 `ip neigh show`에 `FAILED`(반대 방향은 잘 됨)
-> **IP 중복부터 의심** — ARP/방화벽 튜닝 전에. 양쪽 `ip -4 addr show bond0`를 대조하고, `ip route get <상대 IP>`가 `local <IP> dev lo`로 나오면 그 주소는 내 것(= 충돌, 그래서 반대 방향 ping이 '성공'처럼 보였던 것)입니다. web01/was01에 `.21`/`.22`가 남아 있다면 §9-2 0)로 제거(v16 업데이트 1번) |

44. `vagrant up`이 `Timed out while waiting for the machine to boot ("config.vm.boot_timeout")`
-> VM은 실제로 떠 있는 경우가 대부분이니 먼저 `vagrant ssh <이름>`. Vagrantfile에 `config.vm.boot_timeout = 900`이 있는지 확인(§2). 타임아웃으로 중단된 VM은 호스트명이 `localhost.localdomain`이고 관리망 IP가 비어 있을 수 있음 → §3-1, §3-3 (3차 세션: 끝까지 성공한 노드는 자동 적용, db01만 미적용 — v16 추가 반영 1번) |

45. `lsblk`의 디스크 문자/크기가 가이드와 다름(`pvcreate`가 OS 디스크를 대상으로 하게 될 위험)
-> 문자를 믿지 말고 §6-1의 '빈 디스크 스캔'으로 크기 기준 선택. 파티션·마운트가 있는 디스크는 OS 디스크이므로 절대 `pvcreate` 대상이 아님(§11-5도 동일) |

46. Tomcat에서 `ss -tnlp \| grep 8009`에 `[::1]:8009`만 보이거나, `journalctl -u tomcat`에 `secretRequired="true" but the secret attribute is either null or ""`
-> 기본 주석 블록만 푼 상태(`address="::1"`, `secretRequired` 없음). §5-3의 스크립트로 `address`와 `secretRequired="false"`가 함께 든 Connector를 추가 |

47. `curl http://localhost/app/db-check`가 404이고 본문에 `"path":"/app//db-check"`
-> `ajp-proxy.conf`에서 `<Location>`과 `ProxyPass`/`ProxyPassReverse`의 끝 슬래시 유무가 서로 다름(§4-2). 셋을 통일하고 `apachectl configtest` → `systemctl restart httpd` |

48. `firewall-cmd ... --add-rich-rule=\` 뒤에서 `Error: INVALID_RULE: empty rule`
-> 여러 줄 붙여넣기 중 `\`+줄바꿈이 끊겨 규칙 문자열이 빈 채로 실행된 것. 규칙 전체를 한 줄로 이어서 다시 실행(§5-5·§6-11은 한 줄 형태로 수정됨) |

49. `nmcli connection delete "Wired connection N"` 직후 SSH/콘솔이 멈춤
-> `enp0s3`(NAT, `vagrant ssh` 경로)나 `enp0s8`(관리망)에 물린 프로파일을 지웠을 가능성(원인 확정 못 함 — v16 업데이트 9번). 복구: 새 PowerShell에서 `vagrant ssh <VM>` 재시도 → 안 되면 VirtualBox 콘솔에서 로그인해 `nmcli con up <프로파일>` → 그래도 안 되면 `vagrant reload <VM>`. 예방: 삭제 전 `nmcli -f NAME,DEVICE,UUID con show`로 DEVICE 열을 확인하고 `enp0s3`/`enp0s8`에 물린 것은 건드리지 않기 |

50. §3-3의 `nmcli con add ... mgmt-net`을 실행했더니 `nmcli con show`에 `enp0s8`(DEVICE `--`)과 `mgmt-net`이 같이 있음
-> Vagrant가 이미 만든 `enp0s8` 프로파일 위에 중복으로 만든 것(같은 IP라 동작에는 지장 없음). `nmcli -f NAME,DEVICE con show`에서 `enp0s8`의 DEVICE가 `--`일 때만 `nmcli con delete enp0s8`. DEVICE가 `enp0s8`이면 사용 중이라 지우지 않음(§3-3) |

51. §3-5 bond0 블록에서 `Connection '(null)' ((null)) successfully added.` / `The base network connection was interrupted` / `Unable to determine UID of the request`
-> 3차 세션 db01에서 재현, 이어진 검증은 통과(원인 미확정). 판정은 확인 블록의 `✅` + 슬레이브 2개 `up`. 통과했더라도 §3-7 재부팅 뒤에 `nmcli con show --active`로 bond0·bond0-port1·bond0-port2가 모두 활성인지 확인 |

52. `hostnamectl`이 `Static hostname: (unset)` / `Transient hostname: localhost`이고 `enp0s8`에 IPv4가 없음
-> `vagrant up`의 후속 단계(호스트명·private_network)가 적용되지 않은 노드. §3-1로 호스트명을 먼저 설정하고 §3-3 블록 실행. §3-3·§3-5 블록은 호스트명을 보고 IP를 고르므로 호스트명이 먼저여야 함 |

53. 재부팅 직후 `vagrant ssh <VM>`이 아무 출력 없이 PowerShell 프롬프트로 돌아옴 (VirtualBox 콘솔에는 로그인 프롬프트가 떠 있음)
-> Vagrant가 ssh 오류를 숨기기 때문에 그렇게 보입니다. 먼저 기다리고, `vagrant ssh <VM> -- -v`로 실제 오류를 봅니다. 오래 안 되면 콘솔에서 `ip -4 -br addr show enp0s3`(10.0.2.15/24), `systemctl is-active sshd`, `ss -tlnp | grep ':22 '`를 확인(3차 세션은 셋 다 정상 — 기다리면 되는 경우, 원인 미확정) |

54. web01에서 만든 로컬 저장소(`/repo/rocky10/local`)에 `httpd`·`httpd-core` 등이 없음 (`ls | grep -c '^httpd'` → 0)
-> §4-1에서 httpd를 먼저 깔아서 `dnf install --downloadonly`가 건너뛴 것(출력 첫머리 `Package httpd-... is already installed.`). `dnf download --destdir=/repo/rocky10/local <§4-6의 12개>` 후 `createrepo_c --update`(§4-6). was01/db01에는 영향 없음. r20부터 §4-6은 처음부터 `dnf download --resolve --alldeps --destdir=…`를 쓰므로 새로 만들 때는 해당 없음(예전 방식으로 만든 저장소라면 74·75번도 확인) |

55. web01에 `/etc/yum.repos.d/local-web01.repo`가 있고 `dnf repolist`에 `local-web01`만 나옴
-> was01/db01용 저장소 등록 블록을 web01에서 실행한 결과(§4-6). `rm -f /etc/yum.repos.d/local-web01.repo` 후 `dnf config-manager --set-enabled baseos appstream extras` 로 되돌리고 `dnf repolist`로 확인 |

56. `curl -I http://localhost:8080/` → `curl: (7) Failed to connect to localhost port 8080` (tomcat을 막 시작한 직후) / `ss -tlnp | grep 8080` 출력 없음
-> 대개 JVM이 아직 뜨는 중입니다(3차 세션 was01: 시작 후 약 1분 40초). `journalctl -u tomcat --no-pager | grep -E 'Server startup|SEVERE'`에서 `Server startup`이 보일 때까지 기다린 뒤 재시도(§5-2). 안 뜨고 `SEVERE`가 있으면 `journalctl -u tomcat -n 50 --no-pager` |

57. `systemctl show tomcat -p Environment`가 `Environment=NAME=`만 출력
-> 정상입니다(가이드의 예전 '`CATALINA_BASE=…`' 문구가 틀렸음). CATALINA_BASE는 `journalctl -u tomcat --no-pager \| grep 'options used'`의 `-Dcatalina.base=/usr/share/tomcat`로 확인(§5-2) |

58. `ss -tnlp | grep 8009`에 `10.10.10.12:8009`가 아니라 `[::ffff:10.10.10.12]:8009`로 나옴
-> 정상입니다. 자바 소켓이 IPv4 주소를 'IPv4-mapped IPv6'로 표시하는 것이고 `address="10.10.10.12"`가 적용된 상태입니다. 문제는 `[::1]:8009`만 보일 때입니다(§5-3 방법 2) |

59. Tomcat 로그에 Spring 배너가 두 번 나오고 `Root context already created (using as parent).` / `Filter errorPageFilter was not registered (possibly already registered?)`가 찍힘
-> `AppApplication`과 `ServletInitializer`가 둘 다 `SpringBootServletInitializer`를 상속해 앱이 두 번 기동된 것(§5-6-3). 재현 기록 was01: 첫 기동 159.89초 + 둘째 7.327초(시계 설정 후 재측정: 6.171초 + 0.524초, 두 `Started` 줄은 여전히 둘 다 찍힘). 응답 자체는 나오지만(404가 아니라 500) 낭비이므로 `ServletInitializer.java`를 지우고 다시 빌드·배포. 삭제 후 배너가 한 번만 나오는지는 미확인 |

60. `systemctl restart tomcat` 뒤 한참 동안 `curl`이 404/연결 실패 — WAR을 넣은 재시작이 4분 넘게 걸림
-> 재현 기록 was01: `Server startup in [255146] milliseconds`(약 4분 15초, `deployWAR` 248,736 ms). 시계 설정(§5-8) 전 기록이며, 고치고 재부팅한 뒤 다시 재면 `Server startup in [24716] milliseconds`(약 25초)였음(시계가 원인이라고 강하게 시사되지만 재부팅과 분리해 확인하지는 않음). `sudo journalctl -u tomcat --no-pager | grep -E 'Server startup|SEVERE'`에서 `Server startup`이 보일 때까지 기다린 뒤 판단(§5-6-7) |

61. `systemctl status chronyd`는 `active (running)`인데 `chronyc sources`에 `^*`가 없고 journal에 `Can't synchronise: no selectable sources` / `System clock wrong by … seconds`가 반복
-> `active`는 '데몬이 떠 있다'일 뿐 동기화 성공이 아닙니다. 재현 기록 was01: 04:36~04:57 사이 위 메시지가 번갈아 반복됐고, 05:49 재확인에서 `^* web01`(Reach 377)에 도달했지만 `chronyc tracking`은 `System time 3.88 s fast`, `Frequency 1255.873 ppm`으로 여전히 불안정. 판정은 `chronyc sources`/`chronyc tracking`(§5-8). 세 VM 모두 clocksource가 `acpi_pm`(§16-10의 개선 전 상태와 같음) — `--paravirtprovider kvm`으로 `tsc`로 바꾼 뒤 web01 유휴 부하는 줄었지만 이후 was01 `chronyc tracking`은 `Frequency` 44.915 ppm, `Skew` 0.123 ppm, `System time` 약 78 µs slow로 안정됨(§5-8) |

62. §6-1 `echo`에 `pgdata=/dev/sdX pgwal=/dev/sdY pgbackup=/dev/sdZ`가 그대로 찍힘
-> 예시 글자를 실제 디스크로 바꾸지 않은 상태입니다(이후 `pvcreate`가 존재하지 않는 장치로 실패). v16 §6-1은 크기로 자동 대입하고 ✅/❌로 확인하는 블록입니다. 그리고 `sudo -i`를 변수 설정 뒤에 치면 새 root 셸이라 변수가 사라지므로, root 셸에서 블록을 실행합니다 |

63. `journalctl -u …`가 `Hint: You are currently not seeing messages from other users and the system.` / `No journal files were opened due to insufficient permissions.`만 출력
-> `vagrant` 계정으로 실행한 것입니다. `sudo journalctl …`로 붙이거나 `sudo -i`로 root가 된 뒤 실행 |

64. §6-3에서 `rpm -q postgresql-server`가 `package postgresql-server is not installed`로 나옴 / `rm -f /etc/yum.repos.d/pgdg-…`를 실행해야 하는지 헷갈림
-> 정상입니다. 새로 만든 db01에는 설치돼 있지 않으니 `dnf install -y postgresql-server postgresql-contrib`로 로컬 저장소에서 설치합니다(16.15, 63개 패키지). `rm`은 PGDG 저장소를 예전에 추가해 둔 경우에만 — `dnf repolist`에 `local-web01`만 있으면 건너뜁니다(§6-3) |

65. §6-8에서 자리표시자(`'여기에_직접_정한_비밀번호_입력'`)를 그대로 실행해 `CREATE ROLE`이 나옴 / 다시 실행하면 `role "app_user" already exists`, `database "appdb" already exists`
-> 새로 만들지 말고 `sudo -u postgres psql -c "ALTER USER app_user WITH PASSWORD '새값';"`만 실행(재현 기록: `ALTER ROLE`). v16 §6-8 블록은 비밀번호를 실행 때 묻습니다. WAR의 `application.properties` 값과 같은지 꼭 확인 |

66. 가이드의 `> firewall-cmd …`처럼 앞에 `> `가 붙은 채 복사해 실행하면 `-bash: --get-zone-of-interface=bond0: command not found`
-> `>`는 출력 리다이렉션이라 첫 단어가 명령이 아니라 파일 이름(`firewall-cmd`)이 되고, 남은 부분이 명령으로 실행됩니다. 결과: 명령 미실행 + 현재 디렉터리에 빈 파일 생성(`ls -l firewall-cmd`로 확인 후 `rm`). v16에서는 명령이 들어 있는 블록 인용 5곳을 인용 밖으로 뺐습니다 |

67. §6-9 cron 백업이 조용히 실패 / `/pgbackup`에 `backup_*.dump`가 없음
-> `ls -ldZ /pgbackup`이 `root root`이면 postgres가 쓸 수 없는 것. `chown postgres:postgres /pgbackup` 후 `cd /tmp && sudo -u postgres /pgbackup/pg_backup.sh; echo "exit=$?"`로 즉시 확인(§6-9, §15-2, §15-8) |

68. §6-9 즉시 실행 확인에서 `find: Failed to restore initial working directory: /root: Permission denied`와 `exit=1`이 나오는데 덤프 파일은 만들어짐
-> 스크립트 문제가 아니라 실행 위치 문제. `sudo -u postgres`가 root의 현재 디렉터리(`/root`, 700)를 물려받아 마지막 `find`가 거기로 돌아가지 못하고, 그 종료 코드가 스크립트 종료 코드가 됨. `cd /tmp` 후 다시 실행. cron은 홈 디렉터리에서 실행하므로 해당 없을 것으로 보이나 새벽 2시 실행은 미확인 |

69. §7-3 `curl http://localhost:8080/app/db-check`의 출력이 비어 있음 / 성공 메시지 끝에 프롬프트가 붙음(`DB 연결 성공: appdb[root@was01 ~]#`)
-> 프롬프트가 붙는 것은 응답에 줄바꿈이 없어서라 정상입니다. 출력이 아예 없을 때는 `curl -si …| head`로 상태 줄과 본문을 확인. 재현 기록 was01: 첫 실행은 출력이 비었고 바로 다시 실행하자 성공했으며, 첫 번째가 비었던 원인은 확인하지 못했습니다(§7-3) |

70. §9-3에서 rpm 개수가 가이드(111)와 안 맞음 — web02 `ls -la /tmp/ha-pkgs | wc -l`은 113, wget은 `Downloaded: 111 files`, `ls *.rpm | wc -l`은 110
-> 정상입니다. 실제 rpm은 110개이고 나머지는 세는 방법 차이: `ls -la`는 `total`·`.`·`..` 3줄이 더해지고, wget의 111은 목록용 `index.html`이 포함된 값입니다. web02에서도 `ls /tmp/ha-pkgs/*.rpm | wc -l`로 세어 web01과 같은지 비교(§9-3) |

71. §9-3 6번 `curl -I …/corosync-3.1.10-1.el10_2.1.x86_64.rpm`이 `404 Not Found`
-> 파일명의 빌드 번호가 시점마다 다릅니다(2026-10-01 재현에서는 `.el10_2.2`). `ls /repo/rocky10/local/corosync-3*.rpm`으로 실제 파일명을 확인하거나 §9-3의 `f=$(basename …)` 방식으로 조회(§9-3) |

72. §9-6에서 `sudo pcs property set stonith-enabled=false`가 `Error: unable to get cib`
-> 클러스터가 아직 기동 전이라서입니다(CIB는 pacemaker가 떠 있어야 접근 가능). `sudo pcs cluster start --all` 뒤에 다시 실행하고, 기동 직후라면 10초쯤 기다렸다가 재시도(§9-6 3)·4))

73. §10-1에서 만든 `web_vip`/`was_vip`가 `Started`가 아니라 `Stopped`로 남고, `pcs status` 위쪽에 `Resource start-up disabled since no STONITH resources have been defined`, `Configuration invalid (with errors)`가 보임
-> `stonith-enabled`가 아직 `true`인 것(§9-6 4)를 빠뜨림). web01 또는 was01에서 `sudo pcs property set stonith-enabled=false` 후 `sudo pcs property config \| grep -i stonith`와 `pcs status` 재확인. 리소스를 다시 만들 필요는 없었습니다 — 재현 기록: 설정 약 20초 뒤 `Started`가 되고 `WARNINGS` 블록(CIB 경고 포함)도 사라짐(§9-6, §10-1) |

74. was02(또는 was01/db01)의 `dnf install`이 `[MIRROR] …rpm: Status code: 404 for http://192.168.10.111/repo/rocky10/local/…rpm` → `Cannot download, all mirrors were already tried without success`
-> web01의 `repodata`는 그 rpm을 알고 있는데 파일이 디스크에 없는 것입니다(404 = 파일 없음, 403 = SELinux 라벨 문제). 확인: web01 `ls /repo/rocky10/local/*.rpm | wc -l`가 §4-6/§9-3에서 기록한 개수(재현 기록 303)보다 크게 적음(재현 기록 58). 복구: §4-6의 `dnf download --resolve --alldeps --destdir=/repo/rocky10/local …` → `createrepo_c /repo/rocky10/local`(전체 재생성) → `restorecon -Rv /repo/rocky10/local/ \| tail -3` → 클라이언트에서 `sudo dnf clean metadata` 후 재시도(재현 기록: was02 174개 패키지 `Complete!`). 원인과 재발 방지는 75번 |

75. 저장소를 만든 뒤 `/repo/rocky10/local`의 rpm 개수가 줄어듦 (재현 기록: 303 → 58, 줄어든 245개가 §4-6의 `--downloadonly --downloaddir` 결과와 개수가 정확히 같음)
-> 강한 추정: `dnf install --downloadonly --downloaddir=…`로 받은 파일의 경로가 `/var/cache/dnf/tempfiles.json`에 기록되고, 다음에 패키지를 설치하는 성공한 `dnf` 작업이 끝날 때 그 경로의 파일이 지워집니다(업스트림 dnf 소스와 숫자가 맞음. 이 VM의 dnf 버전 코드와 삭제 순간은 확인 못 함). 확인: `sudo cat /var/cache/dnf/tempfiles.json`에 `/repo/rocky10/local/…` 경로가 있으면 위험한 상태. 예방: ① 저장소는 `dnf download --destdir`(기록되지 않음)로 받기 ② 이미 `--downloadonly`를 썼다면 다음 `dnf install` 전에 `echo '[]' \| sudo tee /var/cache/dnf/tempfiles.json`(결과 미확인) ③ 개수 기록 + `cp -a` 백업(§4-6) |

76. `pcs constraint colocation add … INFINITY` 실행 시 `Deprecation Warning: Specifying score as a standalone value is deprecated and might be removed in a future release, use score=value instead`
-> 제약은 만들어졌고 경고일 뿐입니다(pcs 0.12.2). 가이드는 경고가 안내한 `score=INFINITY` 형태로 바꿨지만 그 형태를 직접 실행해 보지는 않았습니다(§10-3) |

77. §10-4 was02에서 `curl http://192.168.10.122/app/db-check` → `curl: (7) Failed to connect to 192.168.10.122 port 80 after 0 ms: Could not connect to server`
-> 기다려서 될 일이 아닙니다(`after 0 ms` = 즉시 거절). was02에는 80번을 듣는 프로세스가 없고 Tomcat은 8080입니다. was02에서는 `curl http://localhost:8080/app/db-check`, web 쪽 전체 경로는 web02에서 `curl http://192.168.10.121/app/db-check`로 확인(§10-4) |

78. `pcs resource create web_vip …` 재실행 시 `Error: 'web_vip' already exists` / `/etc/hosts`에 같은 두 줄이 두 번 들어 있음
-> 둘 다 정상입니다. 이미 만들어져 있다는 뜻이고(`pcs status`로 확인), hosts 중복은 §9-7을 두 번 실행한 결과로 동작에는 지장이 없습니다(필요하면 `sudo vi /etc/hosts`로 한 줄씩 정리)(§9-7, §10-1) |

79. 클라이언트(db02 등)의 `dnf install`이 `Errors downloading metadata for repo 'local-web01': Curl error (7): Could not connect to server for http://192.168.10.111/repo/rocky10/local/repodata/repomd.xml [Failed to connect to 192.168.10.111 port 80 after 1 ms: Could not connect to server]` → `Cannot download repomd.xml: All mirrors were tried`
-> 74번(404)과 다릅니다. 404는 서버는 살아 있는데 rpm 파일이 없는 것이고, 이것은 web01에서 80번을 듣는 프로세스가 없는 것입니다(`after 1 ms` = 즉시 거절). §10-3 이후 Apache는 Pacemaker가 관리하므로 `web_httpd`가 web02에 있으면 web01은 저장소 서버 노릇을 못 합니다. 확인: web01 `sudo pcs status \| grep -E 'web_vip\|web_httpd'`가 `Started web02`. 복구: web02에서 `sudo pcs cluster stop` → web01에서 `Started web01`과 `curl -sI http://192.168.10.111/repo/rocky10/local/repodata/repomd.xml \| head -1`이 `HTTP/1.1 200 OK`인지 확인 → web02에서 `sudo pcs cluster start`(§10-5). 재현 기록: 이 순서로 복구되고 db02 설치가 `Complete!` |

80. `vagrant up db02`(또는 `vagrant status`)가 `Vagrantfile:39: syntax error, unexpected string literal, expecting '}'`로 멈춤
-> Ruby 해시는 항목 사이에 쉼표가 필요한데 db01 블록 끝 `}` 뒤에 쉼표가 없어서입니다. 오류가 가리키는 줄은 새로 넣은 `"db02" => {` 줄이고, 고칠 곳은 그 바로 위 db01 블록의 `}`를 `},`로 바꾸는 것입니다. 고친 뒤 `vagrant status`로 확인(§11-1). 재현 기록: 쉼표를 붙이자 해결 |

81. db02에서 `sudo dnf install -y lvm2 policycoreutils-python-utils`가 `No match for argument: policycoreutils-python-utils` → `Error: Unable to find a match`
-> 로컬 저장소(web01)에 그 패키지가 없는 것이고, dnf는 하나라도 못 찾으면 전체를 중단하므로 `lvm2`도 설치되지 않습니다. 인터넷이 되는 노드는 §3-4에서 외부 저장소로 이미 깔아 둬서 티가 안 났던 것. web01에서 `dnf download --resolve --alldeps --destdir=/repo/rocky10/local policycoreutils-python-utils` → `createrepo_c /repo/rocky10/local` → `restorecon -Rv /repo/rocky10/local/ \| tail -3`(재현 기록: 475 → 490개), db02에서 `sudo dnf clean metadata` 후 재실행. `--enablerepo=baseos --enablerepo=appstream` 우회는 이 PC의 db02에서 `Resolving timed out after 30004 ms`로 멈췄습니다(원인 미확인; §11-5 1)) |

82. §11-6에서 `CREATE ROLE replicator …`를 `<REPLICATION_PASSWORD>` 그대로 실행한 뒤 다시 실행하면 `ERROR: role "replicator" already exists`
-> 첫 실행으로 계정이 이미 만들어졌고 비밀번호가 문자 그대로 `<REPLICATION_PASSWORD>`가 된 상태입니다. `sudo -u postgres psql -c "ALTER ROLE replicator WITH PASSWORD '...';"`(출력 `ALTER ROLE`)로 바꾸고 §11-7의 `PGPASSWORD`에도 같은 값을 씁니다(§11-6) |

83. `pg_controldata | grep wal_log_hints`가 계속 `off` (같은 서버의 `SHOW wal_log_hints;`는 `on`, Standby에서 `CHECKPOINT;`를 해도 `off`)
-> `pg_controldata`는 `SHOW`와 다른 곳(`pg_control` 파일)의 값을 보여줍니다. 재현 기록(db01=Standby): `wal_log_hints = on` 설정·재시작·`CHECKPOINT;` 뒤에도 `off`였다가, Primary(db02)에도 `wal_log_hints = on`을 넣고 재시작한 몇 초 뒤(`sleep 5`) 별도 조작 없이 `on`이 됐습니다. Standby 값이 Primary 쪽 변경을 재생하며 따라간다는 것은 추정입니다. Primary 단계를 아직 안 했다면 §13-4의 순서대로 하고 db01에서 다시 확인 |

84. `sudo -u postgres env PGPASSWORD=<REPLICATION_PASSWORD> pg_basebackup …`이 `-bash: REPLICATION_PASSWORD: No such file or directory`
-> 셸이 `<REPLICATION_PASSWORD>`를 입력 리다이렉트(`<`)로 해석해서 명령이 실행되지 않은 것입니다(무해). `<>` 없이 실제 비밀번호를 따옴표로 감싸 `PGPASSWORD='<REPLICATION_PASSWORD>'`처럼 다시 실행(§13-2, 82번과 같은 종류의 실수) |

85. 승격(`pg_promote()`) 직후 로그에 `cp: cannot create regular file '/pgwal/00000002.history': Permission denied` / `archive command failed with exit code 1`이 반복
-> `/pgwal`이 `root:root`라 postgres가 아카이브를 쓰지 못하는 것입니다. `ls -ldZ /pgwal /pgbackup`으로 확인 → `sudo chown postgres:postgres /pgwal`(`/pgbackup`은 §15-2) → `pg_switch_wal()` 뒤 `pg_stat_archiver`에서 `archived_count`가 늘고 `failed_count`가 그대로면 해결(§12-6). 재현 기록: 둘 다 `root root`였고 `/pgwal`만 고쳐 `archived_count` 2 → 3, `failed_count` 27 유지 |

86. `pg_ctl start -D /pgbackup/pitr_restore`가 실패하고 로그에 `FATAL: data directory "/pgbackup/pitr_restore" has invalid permissions` (§14-3)
-> `pg_basebackup`은 이미 있는 디렉터리의 권한을 바꾸지 않고 `cp -a`는 권한을 그대로 복사하므로, 미리 `mkdir`한 디렉터리의 `0755`가 남은 것입니다. `sudo chmod 700 /pgbackup/pitr_base`를 **복사 전에** 하거나, 이미 복사했다면 `sudo chmod 700 /pgbackup/pitr_restore` 뒤 재기동. 확인: `stat -c "%a %U:%G %n"` → `700 postgres:postgres` (처음 실행의 기록 — 2026-10-05 재현에서는 복사 전에 chmod해 발생하지 않음) |

87. PITR 기동이 `could not start server`로 끝나고 로그에 `cp: cannot stat '/pgwal/…': No such file or directory` / `FATAL: recovery ended before configured recovery target was reached` (§14-3)
-> 복구 지점이 아직 아카이브되지 않은 WAL 세그먼트 안에 있는 것입니다. `pg_walfile_name('<복구 지점 LSN>')`으로 세그먼트 이름 확인 → `ls /pgwal/<이름>`이 없으면 `pg_switch_wal()` → 몇 초 뒤 파일이 생기고 `pg_stat_archiver.failed_count`가 그대로인지 확인한 뒤 재기동. 재현 기록(2026-10-05): 기동 전에 확인해 `...0E`가 없는 것을 발견하고 같은 절차로 미리 해결 |

88. `find / -xdev -name '…'`로 찾았는데 `/pgbackup`·`/pgdata`·`/pgwal` 안의 파일이 하나도 안 나옴 (§15-8)
-> 이 세 경로는 각각 별도 LV(별도 파일시스템)라 `-xdev`가 마운트 경계를 넘지 않아 건너뜁니다. 파일이 '없다'는 증거가 아닙니다 — `sudo find /pgbackup -name '…'`처럼 경로를 직접 지정하거나 `ls -la`로 확인. 재현 기록(2026-10-05): `find / -xdev -name 'backup_*.dump'`는 빈 결과였지만 `ls -la /pgbackup`에는 6개가 있었음 |

---

