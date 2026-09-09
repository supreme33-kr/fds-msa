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

RULES_P0_FILE="/etc/prometheus/rules-p0/p0-test-alert.yml"

apply_expr() {  # $1 = "1" | "0"  → expr: vector(1) == $1
  local rule cur
  rule=$(cat <<YML
groups:
- name: fds-p0-test-alert
  rules:
  - alert: ${ALERT}
    expr: vector(1) == ${1}
    for: 0s
    labels:
      severity: info
      purpose: p0-pipeline-test
      kr: "관측 알림 전달 시험"
    annotations:
      summary: "P0 관측 파이프라인 전달 시험 (Prometheus to Alertmanager)"
      description: "S7b. 참/거짓 조건으로 Firing to 수신 to 해소 전이 확인."
YML
)
  kubectl -n "$PROM_NS" create configmap "$CM" \
    --from-literal=p0-test-alert.yml="$rule" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # 고정 sleep 대신, pod 안 마운트 파일이 실제로 바뀔 때까지 폴링 후 reload (kubelet CM sync 30~90s).
  echo "  configmap 반영 대기 (마운트 파일 폴링, 최대 200s)..."
  for i in $(seq 1 40); do
    cur="$(kubectl -n "$PROM_NS" exec "deploy/$PROM_DEPLOY" -- cat "$RULES_P0_FILE" 2>/dev/null | grep -oE 'vector\(1\) == [01]' | head -1)"
    if [ "$cur" = "vector(1) == $1" ]; then
      kubectl -n "$PROM_NS" exec "deploy/$PROM_DEPLOY" -- wget -qO- --post-data='' localhost:9090/-/reload >/dev/null 2>&1
      echo "  반영 완료 (+$((i*5))s) → reload"
      sleep 3; return 0
    fi
    sleep 5
  done
  echo "  WARN: 200s 내 미반영 ($RULES_P0_FILE). rules-p0 마운트/CM 확인 필요."
  return 1
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
  apply_expr "1"
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
  apply_expr "0"
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
