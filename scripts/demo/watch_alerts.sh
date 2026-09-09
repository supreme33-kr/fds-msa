#!/usr/bin/env bash
# 시연 보조 — Prometheus/Alertmanager 알림 상태를 5초 간격으로 타임스탬프와 함께 출력.
# S7/S8 캡처용 타임라인 로그.
#
# 사용법:
#   PROM_URL=http://localhost:9090 AM_URL=http://localhost:9093 ./watch_alerts.sh
#   (port-forward:  kubectl -n fds port-forward svc/prometheus 9090:9090 &
#                   kubectl -n fds port-forward svc/alertmanager 9093:9093 & )
#   ./watch_alerts.sh | tee "s7s8_alert_timeline_$(date +%Y%m%dT%H%M%S).log"
#
set -euo pipefail
PROM_URL="${PROM_URL:-http://localhost:9090}"
AM_URL="${AM_URL:-http://localhost:9093}"
INTERVAL="${INTERVAL:-5}"

echo "# watch_alerts start $(date -Iseconds)  PROM=${PROM_URL}  AM=${AM_URL}"
while true; do
  ts=$(date -Iseconds)
  prom=$(curl -sS "${PROM_URL}/api/v1/alerts" 2>/dev/null \
          | grep -o '"alertname":"[^"]*"[^}]*"alertstate":"[^"]*"' \
          | sed -E 's/.*"alertname":"([^"]*)".*"alertstate":"([^"]*)".*/\1=\2/' | paste -sd',' - || echo "prom:err")
  am=$(curl -sS "${AM_URL}/api/v2/alerts" 2>/dev/null \
          | grep -o '"alertname":"[^"]*"' | sed -E 's/.*:"([^"]*)"/\1/' | sort -u | paste -sd',' - || echo "am:err")
  echo "${ts}  prom[${prom:-none}]  am_active[${am:-none}]"
  sleep "${INTERVAL}"
done
