#!/usr/bin/env bash
# S7a + S7b + S8 을 한 번에 실행하고 발표용 캡처(raw 로그 + REPORT.md + capture.html)를 생성한다.
# 시나리오 v1.5 정렬 — S7 을 앱(S7a)과 P0 Test Alert(S7b) 두 TC 로 분리.
#
#   Phase 0  환경 스냅샷 (pod / pvc / rules / targets)
#   Phase 1  S7a  합성 거래 → 응답 기준 Rule 트리거 집계 → 지표 전후
#   Phase 2  S7b  P0 Test Alert  vector(1)==1 fire → 수신 → vector(1)==0 clear → resolved
#   Phase 3  S8   kube-state-metrics 중지 → TargetDown firing → 복구 → resolved  (선택 항목)
#   Phase 4  지표 스냅샷 → REPORT.md / capture.html
#
# 산출물:  docs/evidence/_local/s7s8_<timestamp>/  (.gitignore 대상, 로컬 전용)
#
# 사용법:
#   BASE_URL=http://10.1.93.50 ./scripts/demo/run_capture.sh
#   SKIP_S8=1 ./scripts/demo/run_capture.sh          # S8 생략(선택 항목)
#
# 주의(v1.5 §4.2): 합성 데이터만. 로그에 credential 원문 없음. 캡처 정제 시 마스킹 위치 고정.
set -uo pipefail

PROM_NS="${PROM_NS:-fds}";  PROM_DEPLOY="${PROM_DEPLOY:-prometheus}"
NS_KSM="${NS_KSM:-monitoring-api}"; DEPLOY_KSM="${DEPLOY_KSM:-kube-state-metrics}"
BASE_URL="${BASE_URL:-http://10.1.93.50}"
ACCOUNT_ID="${ACCOUNT_ID:-SIM_cap_$(date +%H%M%S)}"
S7A_COUNT="${S7A_COUNT:-40}"
S8_DOWN="${S8_DOWN:-120}"
SKIP_S8="${SKIP_S8:-0}"
POLL="${POLL:-10}"

here="$(cd "$(dirname "$0")" && pwd)"
ts="$(date +%Y%m%dT%H%M%S)"
out="$(cd "${here}/../.." && pwd)/docs/evidence/_local/s7s8_${ts}"
mkdir -p "${out}"
echo "[cap] 산출물 디렉터리: ${out}"

pexec() { kubectl -n "${PROM_NS}" exec "deploy/${PROM_DEPLOY}" -- "$@" 2>/dev/null; }
promq_raw() { pexec wget -qO- "localhost:9090/api/v1/query?query=$1"; }
alerts_snap() {
  promq_raw 'ALERTS' | grep -oE '"alert(name|state)":"[^"]*"' | paste - - \
  | sed -E 's/.*"alertname":"([^"]*)".*"alertstate":"([^"]*)".*/\1=\2/' | sort -u | paste -sd',' -
}

################################################################################
echo; echo "===== Phase 0 : 환경 스냅샷 ====="
{
  echo "# captured: $(date -Iseconds)   host: $(hostname)"
  echo; echo "## pods (fds)";            kubectl -n fds get pod -o wide
  echo; echo "## pods (monitoring-api)"; kubectl -n "${NS_KSM}" get pod -o wide
  echo; echo "## pvc (fds)";             kubectl -n fds get pvc
  echo; echo "## prometheus SA";         kubectl -n fds get deploy "${PROM_DEPLOY}" -o jsonpath='{.spec.template.spec.serviceAccountName}'; echo
  echo; echo "## rules loaded";          pexec wget -qO- localhost:9090/api/v1/rules | grep -o '"name":"[^"]*"'
  echo; echo "## targets (scrapeUrl / health)"
  pexec wget -qO- 'localhost:9090/api/v1/targets?state=active' | sed 's/},{/}\n{/g' \
    | grep -oE '"scrapeUrl":"[^"]*"|"health":"[^"]*"' | paste - -
} | tee "${out}/00_env.txt"

################################################################################
echo; echo "===== Phase 1 : S7a 합성 거래 ====="
BASE_URL="${BASE_URL}" ACCOUNT_ID="${ACCOUNT_ID}" COUNT="${S7A_COUNT}" \
  "${here}/s7a_app_txn.sh" --with-metrics | tee "${out}/10_s7a.txt"

################################################################################
echo; echo "===== Phase 2 : S7b P0 Test Alert ====="
{ echo "=== BEFORE $(date -Iseconds) ==="; promq_raw 'ALERTS'; echo; } > "${out}/20_s7b_alerts.txt"
"${here}/s7b_test_alert.sh" demo | tee "${out}/20_s7b_timeline.txt"
{ echo "=== AFTER $(date -Iseconds) ==="; promq_raw 'ALERTS'; echo; } >> "${out}/20_s7b_alerts.txt"

################################################################################
if [ "${SKIP_S8}" != "1" ]; then
  echo; echo "===== Phase 3 : S8 타깃 다운 (선택 항목) ====="
  NS_KSM="${NS_KSM}" DEPLOY_KSM="${DEPLOY_KSM}" DOWN_SEC="${S8_DOWN}" \
    PROM_NS="${PROM_NS}" PROM_DEPLOY="${PROM_DEPLOY}" \
    "${here}/s8_target_down.sh" | tee "${out}/30_s8_timeline.txt"
else
  echo; echo "===== Phase 3 : S8 생략 (SKIP_S8=1) ====="
fi

################################################################################
echo; echo "===== Phase 4 : 지표 스냅샷 + 리포트 ====="
{
  echo "# captured: $(date -Iseconds)"
  echo; echo "## rule_id 별 fds_detected_total 5m 증가분 (E-K3S: ClusterIP 라운드로빈 노이즈, 참고만)"
  promq_raw 'sum%20by%20(rule_id)%20(increase(fds_detected_total%5B5m%5D))'
  echo; echo; echo "## 거래 저장 성공 rate(1m) (E-K3S: 참고만)"; promq_raw 'sum(rate(transaction_save_success_total%5B1m%5D))'
  echo; echo; echo "## up (job / instance 별)"; promq_raw 'up'
} | tee "${out}/40_metrics.txt"

################################################################################
cat > "${out}/REPORT.md" <<EOF
# S7a / S7b / S8 시연 캡처 — ${ts}

- 환경: **E-K3S** (edge01 임시 단일 노드 k3s, \`fds\` ns). 정본(E-CANON) 재검증 별도.
- 시나리오: v1.5 §6 S7a·S7b·S8
- 캡처 시각: $(date -Iseconds)
- 구현·시연: 이재환 (App/Data/Monitoring/QA)

## S7a — 합성 거래 탐지·기록·지표
- 합성 계정 \`${ACCOUNT_ID}\`, ${S7A_COUNT}건 POST. 상세: \`10_s7a.txt\`
- 트리거 Rule 은 응답 \`fds_rules[].triggered\` 로 집계(거래 건수와 동일시하지 않음).
- 201 = 자원 생성. 업무 승인·실제 송금 아님.

## S7b — P0 Test Alert 전이 (P1-MON-01 AC11)
- \`FDSMonitoringPipelineTest\` : \`vector(1)==1\` fire → Alertmanager 수신 → \`vector(1)==0\` clear → resolved
- 타임라인: \`20_s7b_timeline.txt\` / 전후 알림: \`20_s7b_alerts.txt\`
- 앱 지표와 무관한 참/거짓 조건 — 스크레이프 토폴로지·부하와 독립.

## S8 — 관측 신뢰성 (타깃 다운, 선택 항목)
- \`kube-state-metrics\` replicas 0 → \`up==0\` → \`TargetDown\` firing → 복구 → resolved
- 타깃은 static_config 라 discovery 에서 사라지지 않음(\`up=0\`, 시계열 부재 아님).
- 타임라인: \`30_s8_timeline.txt\`

## 스크레이프 토폴로지 수정
- transaction-api/fds-engine 를 headless Service + dns_sd 로 **파드 단위** 스크레이프.
- 이전 ClusterIP 스크레이프는 3 replica 라운드로빈으로 카운터 리셋 오인 → increase()/rate() 영구 부풀음.
- 확인: \`40_metrics.txt\` 의 "target instance 수" 가 job 별 3.

## 주의 (미확정)
- \`fds-optional-hardening\` 그룹(FDSDetectionBurst 등) 임계값 미확정 — v1.5 §1 "선택적 고도화 후보", P0 아님.
- 이 저장소의 CI 실행 근거는 이번 범위에서 미확보(모든 Private repo 일반화 아님).
- E-K3S 결과는 임시 실증. Gate/티켓 Done 자동 승격 아님. 정본 Namespace/CNI/Source 경계와 구분.
EOF

# --- capture.html ---
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$1"; }
{
  cat <<'HEAD'
<!doctype html><meta charset="utf-8"><title>S7a/S7b/S8 시연 캡처</title>
<style>
 body{font:13px/1.55 -apple-system,"Malgun Gothic",sans-serif;margin:24px;color:#1c2430;background:#fff}
 h1{font-size:19px;margin:0 0 4px} h2{font-size:14px;margin:20px 0 6px;border-left:3px solid #2f6fed;padding-left:8px}
 .meta{color:#5a6472;font-size:12px;margin-bottom:12px}
 pre{background:#0f1626;color:#d7e0ef;padding:12px;border-radius:6px;overflow:auto;font-size:12px;max-height:340px}
 table{border-collapse:collapse;margin:6px 0} td,th{border:1px solid #d4dae3;padding:4px 10px;text-align:left}
 .ok{color:#1a7f37;font-weight:700}.warn{color:#b3541e;font-weight:700}
</style>
HEAD
  echo "<h1>FDS 보안 시연 — S7a / S7b / S8 캡처</h1>"
  echo "<div class=meta>${ts} · E-K3S (edge01 임시 k3s) · 시나리오 v1.5 §6 · 구현·시연: 이재환</div>"
  echo "<h2>Phase 0 · 환경</h2><pre>"; esc "${out}/00_env.txt"; echo "</pre>"
  echo "<h2>Phase 1 · S7a 합성 거래</h2><pre>"; esc "${out}/10_s7a.txt"; echo "</pre>"
  echo "<h2>Phase 2 · S7b P0 Test Alert</h2><pre>"; esc "${out}/20_s7b_timeline.txt"; echo "</pre>"
  [ -f "${out}/30_s8_timeline.txt" ] && { echo "<h2>Phase 3 · S8 타깃 다운</h2><pre>"; esc "${out}/30_s8_timeline.txt"; echo "</pre>"; }
  echo "<h2>Phase 4 · 지표 스냅샷</h2><pre>"; esc "${out}/40_metrics.txt"; echo "</pre>"
} > "${out}/capture.html"

echo
echo "[cap] 완료:"
echo "      ${out}/REPORT.md"
echo "      ${out}/capture.html"
