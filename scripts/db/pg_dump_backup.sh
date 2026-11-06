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
