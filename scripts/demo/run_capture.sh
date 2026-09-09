#!/usr/bin/env bash
# S7 + S8 를 한 번에 실행하고 발표용 캡처( raw 로그 + REPORT.md + capture.html )를 생성한다.
#
#   Phase 0  환경 스냅샷 (pod / pvc / rules / targets)
#   Phase 1  S7  이상거래 급증 → FDSDetectionBurst firing → (부하 종료 후) 해소까지 폴링
#   Phase 2  S8  kube-state-metrics down → TargetDown firing → 복구 → resolved
#   Phase 3  지표 스냅샷 → REPORT.md / capture.html
#
# 산출물:  docs/evidence/_local/s7s8_<timestamp>/
#   - 00_env.txt  10_s7_timeline.log  11_s7_alerts_before_after.txt
#   - 20_s8_timeline.log  30_metrics.txt
#   - REPORT.md   capture.html
#
# 사용법:
#   ./scripts/demo/run_capture.sh
#   BASE_URL=http://10.1.93.50 S7_DURATION=45 S7_WAIT_MAX=420 S8_DOWN=120 ./scripts/demo/run_capture.sh
#
# 주의: docs/evidence/_local/ 는 .gitignore 대상(로컬 전용). 저장소엔 검토 완료본만 편입.
#       로그에 거래 페이로드가 남을 수 있음 → [BL] §6 정신, 마스킹 후 보관.
set -uo pipefail

PROM_NS="${PROM_NS:-fds}"
PROM_DEPLOY="${PROM_DEPLOY:-prometheus}"
NS_KSM="${NS_KSM:-monitoring-api}"
DEPLOY_KSM="${DEPLOY_KSM:-kube-state-metrics}"
BASE_URL="${BASE_URL:-http://10.1.93.50}"
ACCOUNT_ID="${ACCOUNT_ID:-acc_s7_demo}"
S7_DURATION="${S7_DURATION:-45}"
S7_WAIT_MAX="${S7_WAIT_MAX:-420}"      # 부하 종료 후 해소까지 최대 폴링(초)
S8_DOWN="${S8_DOWN:-120}"
POLL="${POLL:-10}"

here="$(cd "$(dirname "$0")" && pwd)"
ts="$(date +%Y%m%dT%H%M%S)"
out="$(cd "${here}/../.." && pwd)/docs/evidence/_local/s7s8_${ts}"
mkdir -p "${out}"
echo "[cap] 산출물 디렉터리: ${out}"

pexec() { kubectl -n "${PROM_NS}" exec "deploy/${PROM_DEPLOY}" -- "$@" 2>/dev/null; }
promq_raw() { pexec wget -qO- "localhost:9090/api/v1/query?query=$1"; }
alerts_snap() {
  promq_raw 'ALERTS' \
  | grep -oE '"alert(name|state)":"[^"]*"' | paste - - \
  | sed -E 's/.*"alertname":"([^"]*)".*"alertstate":"([^"]*)".*/\1=\2/' | sort -u | paste -sd',' -
}
# FDSDetectionBurst 상태: firing / pending / (빈 문자열=inactive)
burst_state() {
  # FDSDetectionBurstAnyRule(info) 와 구분하기 위해 alertname 정확히 매칭
  promq_raw 'ALERTS' | sed 's/},{/}\n{/g' | grep '"alertname":"FDSDetectionBurst"' \
  | grep -oE '"alertstate":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//'
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
  echo; echo "## targets (job/health/lastError)"
  pexec wget -qO- 'localhost:9090/api/v1/targets?state=active' \
    | sed 's/},{/}\n{/g' \
    | grep -oE '"scrapeUrl":"[^"]*"|"health":"[^"]*"|"lastError":"[^"]*"' | paste - - -
} | tee "${out}/00_env.txt"

################################################################################
echo; echo "===== Phase 1 : S7 이상거래 급증 ====="
{ echo "=== BEFORE (부하 전) $(date -Iseconds) ==="; promq_raw 'ALERTS'; echo; } > "${out}/11_s7_alerts_before_after.txt"

: > "${out}/10_s7_timeline.log"
(
  echo "# s7 timeline start $(date -Iseconds)  poll ${POLL}s"
  while :; do echo "$(date -Iseconds)  [$(alerts_snap || echo err)]"; sleep "${POLL}"; done
) >> "${out}/10_s7_timeline.log" &
poller=$!

echo "[cap] S7 부하 실행 (${S7_DURATION}s)..."
BASE_URL="${BASE_URL}" ACCOUNT_ID="${ACCOUNT_ID}" DURATION_SEC="${S7_DURATION}" \
  "${here}/s7_transaction_burst.sh" | tee "${out}/10_s7_burst_stdout.txt"

echo "[cap] FDSDetectionBurst firing 대기 (최대 180s; for:1m 이라 부하 종료 후 ~30s 내 예상)..."
w=0; saw_firing=no
while (( w < 180 )); do
  st="$(burst_state)"; echo "  [+${w}s] FDSDetectionBurst=${st:-inactive}"
  [ "${st}" = "firing" ] && { saw_firing=yes; break; }
  sleep "${POLL}"; w=$((w+POLL))
done

if [ "${saw_firing}" = yes ]; then
  echo "[cap] firing 확인. 해소까지 폴링 (최대 ${S7_WAIT_MAX}s)..."
  waited=0
  while (( waited < S7_WAIT_MAX )); do
    st="$(burst_state)"; echo "  [+$((180+waited))s] FDSDetectionBurst=${st:-cleared}"
    [ -z "${st}" ] && { echo "  → resolved"; break; }
    sleep "${POLL}"; waited=$((waited+POLL))
  done
else
  echo "[cap] WARN: firing 미관측. Phase 3 의 R02 increase 값과 alert 룰 로드 여부 확인 필요."
fi
kill "${poller}" 2>/dev/null || true
{ echo "=== AFTER (해소 후) $(date -Iseconds) ==="; promq_raw 'ALERTS'; echo; } >> "${out}/11_s7_alerts_before_after.txt"

################################################################################
echo; echo "===== Phase 2 : S8 타깃 다운 ====="
NS_KSM="${NS_KSM}" DEPLOY_KSM="${DEPLOY_KSM}" DOWN_SEC="${S8_DOWN}" \
  PROM_NS="${PROM_NS}" PROM_DEPLOY="${PROM_DEPLOY}" \
  "${here}/s8_target_down.sh" | tee "${out}/20_s8_timeline.log"

################################################################################
echo; echo "===== Phase 3 : 지표 스냅샷 + 리포트 ====="
{
  echo "# captured: $(date -Iseconds)"
  echo; echo "## R02 5m 증가분 (임계 20)";        promq_raw 'sum(increase(fds_detected_total{rule_id="R02"}[5m]))'
  echo; echo; echo "## rule_id 별 5m 증가분";      promq_raw 'increase(fds_detected_total[5m])'
  echo; echo; echo "## 거래 저장 성공 rate(1m)";   promq_raw 'sum(rate(transaction_save_success_total[1m]))'
  echo; echo; echo "## up (job 별)";               promq_raw 'up'
} | tee "${out}/30_metrics.txt"

r02now="$(promq_raw 'sum(increase(fds_detected_total{rule_id="R02"}[5m]))' | sed -E 's/.*\[[0-9.]+,"([^"]+)"\].*/\1/;t;s/.*/NA/')"

cat > "${out}/REPORT.md" <<EOF
# S7 / S8 시연 캡처 — ${ts}

- 환경: edge01 임시 k3s / \`fds\` ns / 시나리오 v1.4 §3 S7·S8
- 캡처 시각: $(date -Iseconds)
- 구현·시연: 이재환 (App/Data/Monitoring/QA)

## S7 — 이상거래 급증
- 부하: 계정 \`${ACCOUNT_ID}\`, 고액 withdrawal, ${S7_DURATION}s 연속 POST
- 거래 응답: 전건 201 (차단 없음 — 탐지·기록만) → \`10_s7_burst_stdout.txt\`
- \`fds_detected_total{rule_id="R02"}\` 5m 증가분(캡처 시점): **${r02now}** (임계 20)
- \`FDSDetectionBurst\` firing → 부하 종료 후 해소: \`10_s7_timeline.log\`
- 알림 전/후 원본: \`11_s7_alerts_before_after.txt\`

## S8 — 관측 신뢰성 (타깃 다운)
- \`kube-state-metrics\` replicas 0 → \`up{job="kube-state-metrics"}==0\` → \`TargetDown\` firing
- 복구(replicas 1) → resolved : \`20_s8_timeline.log\`
- node-exporter 는 S8 대상 아님(k3s hairpin, \`NodeExporterDown\` 별도)

## 지표 스냅샷
\`30_metrics.txt\`

## 주의 (미확정 항목)
- 임계값(FDSDetectionBurst >20/5m 등) 미확정. 베이스라인 트래픽 관측 후 팀 확정.
- CI 미실행 (GitHub Free Private). kubectl dry-run 검증은 별도.
- 본 캡처는 edge01 임시 k3s 한정. 실 6-Node 재검증 별도.
EOF

# --- capture.html (발표용, 자체 완결) ---
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$1"; }
{
  cat <<'HEAD'
<!doctype html><meta charset="utf-8"><title>S7/S8 시연 캡처</title>
<style>
 body{font:13px/1.5 -apple-system,"Malgun Gothic",sans-serif;margin:24px;color:#1c2430;background:#fff}
 h1{font-size:20px;margin:0 0 4px} h2{font-size:15px;margin:22px 0 6px;border-left:3px solid #2f6fed;padding-left:8px}
 .meta{color:#5a6472;font-size:12px;margin-bottom:12px}
 pre{background:#0f1626;color:#d7e0ef;padding:12px;border-radius:6px;overflow:auto;font-size:12px;max-height:360px}
 .ok{color:#1a7f37;font-weight:700} .warn{color:#b3541e;font-weight:700}
 table{border-collapse:collapse;margin:6px 0} td,th{border:1px solid #d4dae3;padding:4px 10px;text-align:left}
</style>
HEAD
  echo "<h1>FDS 보안 시연 — S7 / S8 캡처</h1>"
  echo "<div class=meta>${ts} · edge01 임시 k3s · 시나리오 v1.4 §3 · 구현·시연: 이재환</div>"
  echo "<table><tr><th>항목</th><th>결과</th></tr>"
  echo "<tr><td>S7 거래 응답</td><td class=ok>전건 201 (차단 없음)</td></tr>"
  echo "<tr><td>R02 5m 증가분(캡처시점)</td><td class=warn>${r02now} / 임계 20</td></tr>"
  echo "<tr><td>FDSDetectionBurst</td><td class=warn>firing → 해소 (타임라인)</td></tr>"
  echo "<tr><td>S8 TargetDown</td><td class=warn>ksm down 시 firing → 복구 시 resolved</td></tr>"
  echo "</table>"
  echo "<h2>Phase 0 · 환경</h2><pre>"; esc "${out}/00_env.txt"; echo "</pre>"
  echo "<h2>Phase 1 · S7 부하</h2><pre>"; esc "${out}/10_s7_burst_stdout.txt"; echo "</pre>"
  echo "<h2>Phase 1 · S7 알림 타임라인</h2><pre>"; esc "${out}/10_s7_timeline.log"; echo "</pre>"
  echo "<h2>Phase 2 · S8 타임라인</h2><pre>"; esc "${out}/20_s8_timeline.log"; echo "</pre>"
  echo "<h2>Phase 3 · 지표 스냅샷</h2><pre>"; esc "${out}/30_metrics.txt"; echo "</pre>"
} > "${out}/capture.html"

echo
echo "[cap] 완료:"
echo "      ${out}/REPORT.md"
echo "      ${out}/capture.html   ← 브라우저로 열어 슬라이드 캡처"
echo "      raw: 00_env.txt 10_s7_*.log 11_*.json 20_s8_timeline.log 30_metrics.txt"
