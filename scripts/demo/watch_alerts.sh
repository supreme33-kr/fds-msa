#!/usr/bin/env bash
# 시연 보조 — 활성 알림(pending/firing) 상태를 타임스탬프와 함께 주기 출력.
# port-forward 없이 kubectl exec 로 pod 안에서 ALERTS 메트릭을 조회한다.
#   ( /api/v1/alerts 는 alertname 이 labels 하위에 있고 상태 필드가 state 라 파싱이 번거로움 →
#     ALERTS{alertstate=...} 시계열을 쓴다. 라벨 정렬상 alertname < alertstate 이므로 pair 안정적. )
#
# 사용법:
#   ./watch_alerts.sh
#   INTERVAL=10 PROM_NS=fds PROM_DEPLOY=prometheus ./watch_alerts.sh | tee "alert_timeline_$(date +%Y%m%dT%H%M%S).log"
#
set -uo pipefail
PROM_NS="${PROM_NS:-fds}"
PROM_DEPLOY="${PROM_DEPLOY:-prometheus}"
INTERVAL="${INTERVAL:-10}"

snapshot() {
  kubectl -n "${PROM_NS}" exec "deploy/${PROM_DEPLOY}" -- \
    wget -qO- 'localhost:9090/api/v1/query?query=ALERTS' 2>/dev/null \
  | grep -oE '"alert(name|state)":"[^"]*"' \
  | paste - - \
  | sed -E 's/.*"alertname":"([^"]*)".*"alertstate":"([^"]*)".*/\1=\2/' \
  | sort -u | paste -sd',' -
}

echo "# watch_alerts start $(date -Iseconds)  ${PROM_NS}/deploy/${PROM_DEPLOY}  every ${INTERVAL}s"
while true; do
  s="$(snapshot)"
  echo "$(date -Iseconds)  [${s:-none}]"
  sleep "${INTERVAL}"
done
