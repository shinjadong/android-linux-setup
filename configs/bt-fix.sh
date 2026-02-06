#!/system/bin/sh
# bt-fix.sh — 재부팅 시 블루투스 페어링 데이터 초기화
# Magisk service.d: 부팅 완료 후 실행

LOG="/data/local/tmp/bt-fix.log"
BT_CONF="/data/misc/bluedroid/bt_config.conf"

log() { echo "$(date '+%m-%d %H:%M:%S'): $1" >> $LOG; }

log "=== BT fix triggered ==="

if [ ! -f "$BT_CONF" ]; then
  log "bt_config.conf not found, skipping"
  exit 0
fi

# GATT 캐시 삭제
rm -f /data/misc/bluetooth/gatt_cache_* /data/misc/bluetooth/gatt_hash_* 2>/dev/null
log "GATT cache cleared"

# 어댑터 정보만 남기고 페어링 섹션 제거
cp "$BT_CONF" "${BT_CONF}.bak"
awk '
  /^\[/ { section=$0 }
  section ~ /^\[(Info|Metrics|Adapter)\]/ { print; next }
  section ~ /^\[/ && section !~ /^\[(Info|Metrics|Adapter)\]/ { next }
  { print }
' "${BT_CONF}.bak" > "$BT_CONF"

chown bluetooth:bluetooth "$BT_CONF"
chmod 660 "$BT_CONF"
log "Pairing data cleaned"
