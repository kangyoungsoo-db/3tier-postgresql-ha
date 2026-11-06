#!/bin/bash
BACKUP_DIR=/pgbackup
DATE=$(date +%Y%m%d_%H%M%S)
/usr/bin/pg_dump -U postgres -F c -f "${BACKUP_DIR}/backup_${DATE}.dump" appdb
# 7일 지난 백업 파일 자동 삭제
find "${BACKUP_DIR}" -name "backup_*.dump" -mtime +7 -delete
