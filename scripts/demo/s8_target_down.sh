#!/usr/bin/env bash
# S8 실행 A — 관측 신뢰성: 스크레이프 타깃 다운 → TargetDown Firing → 복구 시 Resolved
#   (시나리오 v1.4 §3 S8)
#
#   kube-state-metrics 를 0 replica 로 내렸다가 다시 올리며 up==0 / TargetDown 을 관측한다.
#   node-exporter 는 k3s hairpin 로 이미 DOWN(A6, 전용 룰 NodeExporterDown) 이므로 S8 대상에서 제외.
#
# 사용법:
#   PROM_URL=http://localhost:9090 ./s8_target_down.sh
#   (클러스터 밖에서 실행 시 먼저:  kubectl -n fds port-forward svc/prometheus 9090:9090 & )
#   DOWN_SEC=120 ./s8_target_down.sh
#
set -euo pipefail

NS_KSM="${NS_KSM:-monitoring-api}"
DEPLOY_KSM="${DEPLOY_KSM:-kube-state-metrics}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
DOWN_SEC="${DOWN_SEC:-120}"

q() { curl -sS -G "${PROM_URL}/api/v1/query" --data-urlencode "query=$1" \
        | sed -E 's/.*"value":\[[0-9.]+,"([0-9]+)"\].*/\1/;t;s/.*/NA/'; }

alerts() { curl -sS "${PROM_URL}/api/v1/alerts" \
             | grep -o '"alertname":"[^"]*","alertstate":"[^"]*"' || echo "(no alerts)"; }

echo "[S8] Prometheus       : ${PROM_URL}"
echo "[S8] 대상             : ${NS_KSM}/${DEPLOY_KSM}"
echo "[S8] down 유지 시간   : ${DOWN_SEC}s (TargetDown for: 1m 이상 되도록 90s+ 권장)"
echo
echo "[S8] t0  up{job=kube-state-metrics} = $(q 'up{job="kube-state-metrics"}')  (1=UP 예상)"
echo "[S8] t0  alerts: $(alerts)"
echo

echo "[S8] --- kube-state-metrics scale 0 ---"
kubectl -n "${NS_KSM}" scale deploy/"${DEPLOY_KSM}" --replicas=0
kubectl -n "${NS_KSM}" rollout status deploy/"${DEPLOY_KSM}" --timeout=60s || true

echo "[S8] ${DOWN_SEC}s 대기하며 30s 간격 관측..."
elapsed=0
while (( elapsed < DOWN_SEC )); do
  sleep 30; elapsed=$((elapsed+30))
  echo "  [S8 +${elapsed}s] up=$(q 'up{job="kube-state-metrics"}')  alerts: $(alerts)"
done

echo
echo "[S8] --- kube-state-metrics scale 1 (복구) ---"
kubectl -n "${NS_KSM}" scale deploy/"${DEPLOY_KSM}" --replicas=1
kubectl -n "${NS_KSM}" rollout status deploy/"${DEPLOY_KSM}" --timeout=90s || true

echo "[S8] 복구 후 최대 4분간 Resolved 관측..."
for i in $(seq 1 8); do
  sleep 30
  echo "  [S8 recover +$((i*30))s] up=$(q 'up{job="kube-state-metrics"}')  alerts: $(alerts)"
done

echo
echo "[S8] 완료. 캡처 대상:"
echo "     - Prometheus /alerts : TargetDown pending→firing→(빈 목록) 타임라인"
echo "     - Alertmanager UI    : TargetDown Firing → Resolved"
echo "     - Grafana 'Target Health' : up 패널이 0 으로 떨어졌다 복구"
