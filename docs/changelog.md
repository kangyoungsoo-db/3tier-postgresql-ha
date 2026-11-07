> 이 문서는 `3tier-rocky10-guide-v16.md` 의 1~183줄(개정 기록)을 버전별로 줄인 것이다. 자세한 내용은 각 장에 반영돼 있다.

# 개정 기록

## 진행 상태

- ✅ Phase 1 완료: Apache(web01:80) → AJP → Tomcat(was01:8009) → JDBC → PostgreSQL(db01:5432) 흐름을 §7 End-to-End 5단계로 검증했다.
- ✅ Phase 2 완료: web_vip(10.10.10.14), was_vip(10.10.10.15) 등록, httpd/tomcat을 pacemaker 리소스로 전환, 페일오버 테스트까지 검증했다(§9, §10).
- ✅ Phase 2+ 완료: db02를 db01의 Standby로 붙여 `streaming` 상태와 실제 데이터 복제를 확인했다(§11).
- ✅ 수동 페일오버 연습 완료: db02 승격(§12), db01 재동기화(§13), PITR 복구 드릴(§14). 기록 시점 기준 db02가 Primary, db01이 Standby다.
- ✅ pg_dump 논리 백업 자동화 완료: db02에서 매일 02:00 자동 실행, 7일 지난 백업은 자동 삭제(§15).

## 버전별 요약

- **v16 추가 반영**: VM을 새로 만들어 §3을 다시 따라 한 재현 기록 3개(web01, was01, db01)와 이후 장별 재현 기록을 v16과 대조해 22개 항목을 고쳤다.
  대조 결과 반영: §2, §3-1, §3-3, §3-5, §3-7, §4-2, §4-6, §5-1, §5-3, §5-5, §5-6-3, §5-6-7, §5-8, §6-1, §6-2, §6-3, §6-4, §6-8, §6-9, §6-10, §6-11, §6-12, §6-13, §9-2, §9-3, §9-4, §9-6, §9-8, §10-3, §10-4, §10-5, §11-1, §11-3, §11-5, §11-6, §11-14, §13-2, §13-4, §14-2, §14-3, §15, §15-8, 체크리스트 50~88번, 부록 A.
- **v16 업데이트**: 내 PC(Windows + VirtualBox)에서 §1부터 다시 재현한 기록 5개를 v15와 대조했다. web02/was02 → web01/was01 방향만 안 되던 문제의 원인을 IP 중복으로 확정하고, web01/was01 bond0는 기본 IP 하나만 쓰게 고쳤다.
  그 밖에 `boot_timeout` 900초, 호스트명으로 IP를 고르는 bond0 블록, 크기로 디스크를 고르는 LVM, AJP Connector 추가 스크립트, rich-rule 한 줄화, `tcpdump` 공통 설치, 부록 A(Ansible 검토), 체크리스트 42~49번.
  관련 장: §0, §2, §3-4, §3-5, §4-2, §5-3, §5-5, §6-1, §6-11, §9-2, §11-5.
- **v14**: pg_dump 논리 백업 자동화(§15) 신규 작성. `/pgbackup` 소유권 문제(§15-2), 데이터 디렉터리 안 스크립트를 SELinux가 조용히 거부하는 문제(§15-4)를 해결하고, db01의 기존 §6-9 cron은 폐기했다(§15-8).
- **v13**: PITR 드릴(§14) 완료. 별도 포트(5433) 인스턴스로 복구했고, 데이터 디렉터리 권한 `0755` 문제(`chmod 700`)와 복구 지점 세그먼트 미아카이브 문제(`pg_switch_wal()`)를 해결했다.
- **v12**: §13을 실제로 실행(13-1~13-4)하고 로그를 반영했다. INSERT가 사라진 문제(13-3)와 `pg_controldata` 값이 스냅샷이라는 점(13-4, 이후 v16 재현에서 정정)을 다뤘다.
- **v11**: db01 재동기화 절차(§13) 신규 작성. `pg_rewind` 조건 미충족으로 `pg_basebackup` 경로를 기본으로 하고, db02 `pg_hba.conf` 규칙 추가(13-2-2), `wal_log_hints=on` 선택 항목(13-4)을 넣었다.
- **v10**: 수동 페일오버(§12) 신규 작성. `pg_promote()` 수동 승격, `/pgwal` 소유권 때문에 WAL 아카이빙이 실패하던 문제를 §6-4에 소급 수정(§12-6), 실행 전 스냅샷(§12-1).
- **v9**: db02 복제 마무리(§11-9~§11-13). `listen_addresses`를 `10.10.10.24`로 수정(§11-11), 실제 쓰기로 복제 검증(§11-10), `systemctl enable`은 맨 마지막(§11-12).
- **v8**: db02 스트리밍 복제(§11) 신규 작성. 같은 빌드(AppStream `postgresql-server`) 설치, PGDATA override 복사, `initdb` 대신 `pg_basebackup`, `replicator` 계정 분리, db02 IP는 `10.10.10.24` 하나.
  관련 장: §11-2, §11-3, §11-5, §11-6, §11-7.
- **v7**: Phase 2 마무리(§10) 신규 작성. sudo tee, `ssl.conf` 비활성화, AJP 대상을 was_vip(10.10.10.15)로, `secretRequired="false"`, 페일오버 확인은 반대쪽 노드에서, `pcs resource cleanup`.
  관련 장: §10-2-1, §10-2-2, §10-2-5, §10-2-7, §10-4.
- **v6**: Phase 2 준비(§9) 전면 재구성. `highavailability` 저장소, `restorecon`, 방화벽 `high-availability` 개방, `/etc/hosts` 등록, web02/was02 bond0 단계 분리, VIP를 10.10.10.14/15로 조정.
  관련 장: §9-2, §9-3, §9-5, §9-6, §9-7, §9-9.
- **v5**: Phase 1 마무리(§7 End-to-End) 중 겪은 문제 반영. db01 bond0 IP 충돌 확인 절차(§3-5), `listen_addresses`(§6-7), pom.xml 완성본과 Maven Wrapper, `-DskipTests`, 배포 `sudo`(§5-6), `unzip` 공통 설치(§3-4), PowerShell `curl.exe`(§7).
- **v3/v4**: PostgreSQL 16.14 채택, `lvm2`를 §4-6 목록에 추가, Tomcat은 RPM(`tomcat9`) 설치, AJP 설정 파일을 `/usr/share/tomcat/conf/server.xml`로 정정, Spring Boot 2.7.18로 확정(§5-6), `@GetMapping("/db-check")`로 수정.
