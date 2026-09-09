#!/usr/bin/env bash
# 멘토 발표용 라이브 데모 (약 6~9분). 화면 공유하며 엔터로 단계 진행.
#   시나리오 v1.5 §6 — E-K3S(edge01 임시 k3s) 임시 실증.
#
#   0  베이스라인 — 현재 알림 상태
#   A  S7b  P0 관측 파이프라인 시험 알림  vector(1)==1 → Prometheus firing → Alertmanager 수신 → 해소
#   B  S7a  이상거래 급증  고액·연속 합성 거래 → 201 + fds_rules(R01/R02) → DB 저장 확인
#   C  S8   관측 타깃 다운  kube-state-metrics 강제 중지 → TargetDown firing → Alertmanager 수신 → 복구
#   Z  정리 — 규칙 원복, ksm 복구, 알림 해소 확인
#
# 준비: 별도 창에서 Alertmanager UI 를 띄워 함께 보여준다.
#   kubectl -n fds port-forward svc/alertmanager 9093:9093    → http://localhost:9093
#   kubectl -n fds port-forward svc/grafana 3000:3000         → http://localhost:3000 (admin/admin)
#
# 사용법:
#   ./scripts/demo/demo_live.sh            # 엔터로 단계 진행(권장)
#   AUTO=1 ./scripts/demo/demo_live.sh     # 자동 진행(sleep)
#   STEP=B ./scripts/demo/demo_live.sh     # 특정 단계만 (A|B|C)
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
PROM_NS="${PROM_NS:-fds}"; PROM_DEPLOY="${PROM_DEPLOY:-prometheus}"
AM_NS="${AM_NS:-fds}";     AM_DEPLOY="${AM_DEPLOY:-alertmanager}"
NS_KSM="${NS_KSM:-monitoring-api}"; DEPLOY_KSM="${DEPLOY_KSM:-kube-state-metrics}"
BASE_URL="${BASE_URL:-http://10.1.93.50}"
AUTO="${AUTO:-0}"; STEP="${STEP:-ALL}"

c_hd=$'\e[1;36m'; c_ok=$'\e[1;32m'; c_wn=$'\e[1;33m'; c_dim=$'\e[2m'; c_0=$'\e[0m'
hr(){ printf '%s\n' "────────────────────────────────────────────────────────"; }
say(){ printf '\n%s▶ %s%s\n' "$c_hd" "$*" "$c_0"; }
note(){ printf '%s  %s%s\n' "$c_dim" "$*" "$c_0"; }
pause(){ if [ "$AUTO" = 1 ]; then sleep "${1:-4}"; else read -rp $'\n'"  ⏎ 다음 단계... " _; fi; }

pexec(){ kubectl -n "$PROM_NS" exec "deploy/$PROM_DEPLOY" -- "$@" 2>/dev/null; }
amexec(){ kubectl -n "$AM_NS" exec "deploy/$AM_DEPLOY" -- "$@" 2>/dev/null; }

prom_alerts(){  # firing/pending 요약
  pexec wget -qO- 'localhost:9090/api/v1/query?query=ALERTS' \
  | sed 's/},{/}\n{/g' | grep -oE '"alert(name|state)":"[^"]*"' | paste - - \
  | sed -E 's/.*"alertname":"([^"]*)".*"alertstate":"([^"]*)".*/  \1 = \2/' | sort -u
}
am_active(){    # Alertmanager 가 실제로 받은 알림
  amexec wget -qO- 'localhost:9093/api/v2/alerts' \
  | sed 's/},{/}\n{/g' | grep -oE '"alertname":"[^"]*"|"status":\{"state":"[^"]*"' \
  | sed -E 's/"alertname":"([^"]*)"/  ↳ \1/; s/.*"state":"([^"]*)"/     status=\1/' | paste - -
}
prom_state(){   # $1 = alertname
  pexec wget -qO- 'localhost:9090/api/v1/query?query=ALERTS' | sed 's/},{/}\n{/g' \
  | grep "\"alertname\":\"$1\"" | grep -oE '"alertstate":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//'
}

banner(){
cat <<EOF
${c_hd}╔══════════════════════════════════════════════════════════╗
║  FDS 보안 관측 — 라이브 데모 (E-K3S / edge01 임시 k3s)   ║
║  공격 → 기존 통제 반응 → Prometheus → Alertmanager 수신  ║
╚══════════════════════════════════════════════════════════╝${c_0}
  Alertmanager UI : http://localhost:9093   (별도 창에서 함께 보기)
  Grafana         : http://localhost:3000
  주의: 합성 데이터만. 거래는 통과(201)하며 탐지·기록만 한다. 자금 이동 없음.
EOF
}

step0(){
  say "0. 베이스라인 — 지금 활성 알림"
  hr; prom_alerts; hr
  note "node-exporter/kubelet 은 k3s 단일노드 hairpin 로 상시 firing(info). 실 6노드에서 정석."
  pause 3
}

stepA(){
  say "A. [공격] 관측 파이프라인이 살아있나 — P0 Test Alert 점화"
  note "규칙 FDSMonitoringPipelineTest 를 vector(1)==1 로 바꿔 강제 Firing. 앱 지표와 무관한 전달경로 검증."
  "$here/s7b_test_alert.sh" fire || true
  say "A. Prometheus 규칙 상태 / Alertmanager 수신"
  hr; prom_alerts; echo; echo "  Alertmanager 수신:"; am_active; hr
  note "→ 화면(Alertmanager UI)에 FDSMonitoringPipelineTest 가 떴는지 함께 확인."
  pause 5
  say "A. [복구] 조건 해소 — vector(1)==0"
  "$here/s7b_test_alert.sh" clear || true
  hr; prom_alerts; hr
  note "→ Prometheus inactive + Alertmanager active 목록에서 해제 = Resolved."
  pause 3
}

stepB(){
  say "B. [공격] 이상거래 급증 — 한 합성 계정, 고액 withdrawal 연속"
  note "정상 통제(탐지·기록)만 동작. 거래는 201 로 통과한다."
  BASE_URL="$BASE_URL" ACCOUNT_ID="SIM_live_$(date +%H%M%S)" COUNT="${B_COUNT:-25}" INTERVAL_SEC=0.4 \
    "$here/s7a_app_txn.sh" || true
  note "→ 응답의 fds_rules[].triggered 로 어떤 Rule 이 걸렸는지 표시됨(R01/R02 등). 거래 건수와 동일시하지 않음."
  note "→ 저장 확인(승인 운영 경로):"
  echo "     psql -h 10.1.93.55 -U fds_app -d fdsdb -c \"select transaction_id,amount,fds_detected,fds_rules from transactions order by received_at desc limit 5;\""
  pause 5
}

stepC(){
  say "C. [공격] 관측 타깃 다운 — kube-state-metrics 강제 중지"
  kubectl -n "$NS_KSM" scale deploy/"$DEPLOY_KSM" --replicas=0
  note "up{job=\"kube-state-metrics\"} 가 0 이 되고, for:1m 후 TargetDown 이 pending→firing."
  for i in 1 2 3 4 5 6; do
    sleep 25
    st="$(prom_state TargetDown)"
    printf '  [+%ds] TargetDown = %s   up(ksm)=%s\n' "$((i*25))" "${st:-inactive}" \
      "$(pexec wget -qO- 'localhost:9090/api/v1/query?query=up%7Bjob%3D%22kube-state-metrics%22%7D' | grep -oE '"value":\[[0-9.]+,"[0-9]"\]' | grep -oE '"[0-9]"$' | tr -d '"')"
    [ "$st" = firing ] && break
  done
  say "C. Alertmanager 수신"
  hr; am_active; hr
  say "C. [복구] kube-state-metrics 재기동"
  kubectl -n "$NS_KSM" scale deploy/"$DEPLOY_KSM" --replicas=1
  kubectl -n "$NS_KSM" rollout status deploy/"$DEPLOY_KSM" --timeout=90s || true
  for i in 1 2 3 4 5 6; do
    sleep 25
    st="$(prom_state TargetDown)"
    printf '  [복구 +%ds] TargetDown = %s\n' "$((i*25))" "${st:-resolved}"
    [ -z "$st" ] && { echo "  → Resolved"; break; }
  done
  pause 3
}

stepZ(){
  say "Z. 정리 상태 확인"
  "$here/s7b_test_alert.sh" clear >/dev/null 2>&1 || true
  kubectl -n "$NS_KSM" scale deploy/"$DEPLOY_KSM" --replicas=1 >/dev/null 2>&1 || true
  hr; prom_alerts; hr
  note "FDSMonitoringPipelineTest / TargetDown 이 목록에 없으면 정리 완료."
  note "상시 firing(NodeExporterDown/KubeletScrapeDownK3s)은 k3s 한계 — 발표에서 그대로 설명."
}

banner
case "$STEP" in
  A) stepA ;;
  B) stepB ;;
  C) stepC ;;
  *) step0; stepA; stepB; stepC; stepZ ;;
esac
say "데모 종료. 화면(Alertmanager UI)과 이 로그를 함께 캡처하면 발표 증적이 된다."
