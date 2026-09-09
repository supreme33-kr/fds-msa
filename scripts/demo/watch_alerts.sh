#!/usr/bin/env bash
# 시연 보조 — Prometheus 알림 상태를 타임스탬프와 함께 주기 출력 (S7/S8 캡처 타임라인).
# port-forward 없이 `kubectl exec deploy/prometheus -- wget` 로 pod 안에서 조회.
#
# 사용법:
#   ./watch_alerts.sh
#   INTERVAL=5 PROM_NS=fds PROM_DEPLOY=prometheus ./watch_alerts.sh | tee "alert_timeline_$(date +%Y%m%dT%H%M%S).log"
#
set -uo pipefail
PROM_NS="${PROM_NS:-fds}"
PROM_DEPLOY="${PROM_DEPLOY:-prometheus}"
INTERVAL="${INTERVAL:-10}"

echo "# watch_alerts start $(date -Iseconds)  ${PROM_NS}/deploy/${PROM_DEPLOY}  every ${INTERVAL}s"
while true; do
  line=$(kubectl -n "${PROM_NS}" exec "deploy/${PROM_DEPLOY}" -- \
           wget -qO- localhost:9090/api/v1/alerts 2>/dev/null \
         | grep -o '"alertname":"[^"]*","alertstate":"[^"]*"' \
         | sed -E 's/"alertname":"([^"]*)","alertstate":"([^"]*)"/\1=\2/' | paste -sd',' -)
  echo "$(date -Iseconds)  [${line:-none}]"
  sleep "${INTERVAL}"
done
