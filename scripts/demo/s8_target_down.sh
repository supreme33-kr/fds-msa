#!/usr/bin/env bash
# S8 실행 A — 관측 신뢰성: 스크레이프 타깃 다운 → TargetDown Firing → 복구 시 Resolved
#   (시나리오 v1.4 §3 S8)
#
#   kube-state-metrics 를 0 replica 로 내렸다가 다시 올리며 up==0 / TargetDown 을 관측한다.
#   node-exporter 는 k3s hairpin 로 이미 DOWN(A6, 전용 룰 NodeExporterDown) 이므로 S8 대상에서 제외.
#
# Prometheus 조회는 port-forward 없이 `kubectl exec deploy/prometheus -- wget` 로 pod 안에서 수행.
# 스크립트가 중단(Ctrl-C)돼도 trap 으로 kube-state-metrics 를 replicas=1 로 되돌린다.
#
# 사용법:
#   ./s8_target_down.sh
#   DOWN_SEC=120 ./s8_target_down.sh
#   PROM_NS=fds PROM_DEPLOY=prometheus NS_KSM=monitoring-api DEPLOY_KSM=kube-state-metrics ./s8_target_down.sh
#
set -uo pipefail

PROM_NS="${PROM_NS:-fds}"
PROM_DEPLOY="${PROM_DEPLOY:-prometheus}"
NS_KSM="${NS_KSM:-monitoring-api}"
DEPLOY_KSM="${DEPLOY_KSM:-kube-state-metrics}"
DOWN_SEC="${DOWN_SEC:-120}"

promq() {
  # $1 = PromQL. 스칼라/벡터 첫 값만 추출, 없으면 NA.
  kubectl -n "${PROM_NS}" exec "deploy/${PROM_DEPLOY}" -- \
    wget -qO- "localhost:9090/api/v1/query?query=$1" 2>/dev/null \
  | sed -E 's/.*"value":\[[0-9.]+,"([^"]+)"\].*/\1/; t; s/.*/NA/'
}

alerts() {
  kubectl -n "${PROM_NS}" exec "deploy/${PROM_DEPLOY}" -- \
    wget -qO- "localhost:9090/api/v1/alerts" 2>/dev/null \
  | grep -o '"alertname":"[^"]*","alertstate":"[^"]*"' | paste -sd' , ' - || echo "(no alerts)"
}

restore_ksm() {
  echo
  echo "[S8] (trap) kube-state-metrics 복구 → replicas=1"
  kubectl -n "${NS_KSM}" scale deploy/"${DEPLOY_KSM}" --replicas=1 >/dev/null 2>&1 || true
}
trap restore_ksm EXIT

echo "[S8] Prometheus       : ${PROM_NS}/deploy/${PROM_DEPLOY} (in-cluster exec)"
echo "[S8] 대상             : ${NS_KSM}/${DEPLOY_KSM}"
echo "[S8] down 유지 시간   : ${DOWN_SEC}s (TargetDown for: 1m → 90s+ 권장)"
echo

# Prometheus 도달 확인
if ! kubectl -n "${PROM_NS}" exec "deploy/${PROM_DEPLOY}" -- wget -qO- localhost:9090/-/ready >/dev/null 2>&1; then
  echo "[S8] ERROR: Prometheus(${PROM_NS}/deploy/${PROM_DEPLOY}) 에 접근 불가. NS/deploy 이름 확인." >&2
  exit 1
fi

echo "[S8] t0  up{job=kube-state-metrics} = $(promq 'up{job="kube-state-metrics"}')  (1=UP 예상)"
echo "[S8] t0  alerts: $(alerts)"
echo

echo "[S8] --- kube-state-metrics scale 0 ---"
kubectl -n "${NS_KSM}" scale deploy/"${DEPLOY_KSM}" --replicas=0
kubectl -n "${NS_KSM}" rollout status deploy/"${DEPLOY_KSM}" --timeout=60s || true

echo "[S8] ${DOWN_SEC}s 대기하며 30s 간격 관측..."
elapsed=0
while (( elapsed < DOWN_SEC )); do
  sleep 30; elapsed=$((elapsed+30))
  echo "  [S8 +${elapsed}s] up=$(promq 'up{job="kube-state-metrics"}')  alerts: $(alerts)"
done

echo
echo "[S8] --- kube-state-metrics scale 1 (복구) ---"
kubectl -n "${NS_KSM}" scale deploy/"${DEPLOY_KSM}" --replicas=1
kubectl -n "${NS_KSM}" rollout status deploy/"${DEPLOY_KSM}" --timeout=90s || true

echo "[S8] 복구 후 최대 4분간 Resolved 관측..."
for i in $(seq 1 8); do
  sleep 30
  echo "  [S8 recover +$((i*30))s] up=$(promq 'up{job="kube-state-metrics"}')  alerts: $(alerts)"
done

echo
echo "[S8] 완료. 캡처 대상:"
echo "     - Prometheus /alerts : TargetDown pending→firing→(해소) 타임라인"
echo "     - Alertmanager UI    : TargetDown Firing → Resolved"
echo "     - Grafana 'Target Health' : up 패널이 0 으로 떨어졌다 복구"
# trap restore_ksm 가 EXIT 시 한 번 더 replicas=1 보장
