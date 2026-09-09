#!/usr/bin/env bash
# S7b / TC-ALERT — 기존 P0 Test Alert 전이 (시나리오 v1.5 §6 S7b, P1-MON-01 AC11)
#
#   앱 업무 지표와 무관하게 Prometheus→Alertmanager 전달 경로를 검증한다.
#     fire  : rule expr = vector(1) == 1  → Firing
#     clear : rule expr = vector(1) == 0  → 빈 벡터 → Resolved
#   (vector(0) 단독은 시계열 잔존으로 해소 안 됨 → 쓰지 않음. v1.5 §6 S7b)
#
#   기본 규칙 파일: kubernetes/monitoring/p0-test-alert.yaml (ConfigMap prometheus-p0-test-alert).
#   이 스크립트는 그 ConfigMap 의 expr 만 바꿔 apply 하고 /-/reload 한다. 원상복구(clear)까지가 1 TC.
#
# 사용법:
#   ./s7b_test_alert.sh demo          # fire → 수신 확인 → clear → 해소 확인 (권장)
#   ./s7b_test_alert.sh fire
#   ./s7b_test_alert.sh clear
#
set -uo pipefail
PROM_NS="${PROM_NS:-fds}"; PROM_DEPLOY="${PROM_DEPLOY:-prometheus}"
AM_NS="${AM_NS:-fds}"; AM_DEPLOY="${AM_DEPLOY:-alertmanager}"
ALERT="FDSMonitoringPipelineTest"
POLL="${POLL:-10}"
CM="prometheus-p0-test-alert"

apply_expr() {  # $1 = "== 1" | "== 0"
  local rule
  rule=$(cat <<YML
groups:
- name: fds-p0-test-alert
  rules:
  - alert: ${ALERT}
    expr: vector(1) ${1}
    for: 30s
    labels:
      severity: info
      purpose: p0-pipeline-test
    annotations:
      summary: "P0 관측 파이프라인 전달 시험 (Prometheus→Alertmanager)"
      description: "S7b. 참/거짓 조건으로 Firing→수신→해소 전이 확인."
YML
)
  kubectl -n "$PROM_NS" create configmap "$CM" \
    --from-literal=p0-test-alert.yml="$rule" --dry-run=client -o yaml | kubectl apply -f -
  # ConfigMap 이 pod 에 sync 될 때까지 대기 후 reload (kubelet sync ~30-60s).
  echo "  (configmap sync 대기 ~40s)"; sleep 40
  kubectl -n "$PROM_NS" exec "deploy/$PROM_DEPLOY" -- wget -qO- --post-data='' localhost:9090/-/reload >/dev/null 2>&1
  sleep 5
}

prom_state() {
  kubectl -n "$PROM_NS" exec "deploy/$PROM_DEPLOY" -- wget -qO- 'localhost:9090/api/v1/query?query=ALERTS' 2>/dev/null \
  | sed 's/},{/}\n{/g' | grep "\"alertname\":\"${ALERT}\"" \
  | grep -oE '"alertstate":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//'
}
am_has() {
  kubectl -n "$AM_NS" exec "deploy/$AM_DEPLOY" -- wget -qO- 'localhost:9093/api/v2/alerts' 2>/dev/null \
  | grep -q "\"alertname\":\"${ALERT}\""
}

fire() {
  echo "[S7b] fire — expr = vector(1) == 1"
  apply_expr "== 1"
  for i in $(seq 1 18); do
    st="$(prom_state)"; recv=$(am_has && echo yes || echo no)
    echo "  [+$((i*POLL))s] prometheus=${st:-inactive}  alertmanager_수신=${recv}"
    [ "$st" = firing ] && [ "$recv" = yes ] && { echo "[S7b] Firing + Alertmanager 수신 확인."; return 0; }
    sleep "$POLL"
  done
  echo "[S7b] WARN: 3분 내 firing+수신 미확인. rule 로드/route/receiver 설정 확인 필요."; return 1
}
clear_() {
  echo "[S7b] clear — expr = vector(1) == 0"
  apply_expr "== 0"
  for i in $(seq 1 18); do
    st="$(prom_state)"; recv=$(am_has && echo yes || echo no)
    echo "  [+$((i*POLL))s] prometheus=${st:-inactive}  alertmanager_active=${recv}"
    [ -z "$st" ] && [ "$recv" = no ] && { echo "[S7b] Resolved (prometheus inactive + alertmanager active 목록 해제)."; return 0; }
    sleep "$POLL"
  done
  echo "[S7b] WARN: 3분 내 해소 미확인."; return 1
}

case "${1:-demo}" in
  fire)  fire ;;
  clear) clear_ ;;
  demo)
    fire || true
    echo "[S7b] 30s 유지 후 clear..."; sleep 30
    clear_ || true
    echo "[S7b] 완료. 규칙은 기본(clear=비활성) 상태로 복구됨."
    ;;
  *) echo "usage: $0 [demo|fire|clear]"; exit 2 ;;
esac
