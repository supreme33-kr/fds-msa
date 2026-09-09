#!/usr/bin/env bash
# S7 — 이상거래 급증 부하 발생기 (시나리오 v1.4 §3 S7)
#
#   한 계정으로 30~60초 동안 고액 withdrawal 을 연속 POST 한다.
#   목적: fds_detected_total{rule_id="R02"} 급증 → FDSDetectionBurst Firing →
#         Alertmanager UI Firing → Grafana "Application & FDS" 임계선 초과.
#   거래는 계속 201 (차단 없음 — 탐지·기록만).
#
# 통제/원칙:
#   - 신규 통제 아님. 기존 Baseline Acceptance/Negative 흐름을 공격 시나리오로 실행할 뿐.
#   - R02 threshold = 3,000,000 KRW (fds-engine/app/rules.py, 초안값). AMOUNT 기본을 그 위로 둔다.
#   - 캡처(로그)에 거래 페이로드가 남으므로 [BL] §6 정신에 따라 마스킹 후 보관, 원문 저장 금지.
#
# 사용법:
#   BASE_URL=http://10.1.93.50 ./s7_transaction_burst.sh
#   DURATION_SEC=45 INTERVAL_SEC=0.4 AMOUNT=3500000 ACCOUNT_ID=acc_s7_demo ./s7_transaction_burst.sh
#   DRY_RUN=1 ./s7_transaction_burst.sh          # 요청 본문만 출력, 전송 안 함
#
set -euo pipefail

BASE_URL="${BASE_URL:-http://10.1.93.50}"          # edge01 nginx reverse proxy. 대안: http://<node-ip>:30080
ENDPOINT="${ENDPOINT:-/api/v1/transactions}"
ACCOUNT_ID="${ACCOUNT_ID:-acc_s7_demo}"
AMOUNT="${AMOUNT:-3500000}"                        # >= R02 threshold(3,000,000)
CURRENCY="${CURRENCY:-KRW}"
TXN_TYPE="${TXN_TYPE:-withdrawal}"                 # withdrawal → R02 + (10분내 3회↑ 시) R01
SOURCE_IP="${SOURCE_IP:-203.0.113.77}"
DURATION_SEC="${DURATION_SEC:-45}"
INTERVAL_SEC="${INTERVAL_SEC:-0.5}"
DRY_RUN="${DRY_RUN:-0}"

url="${BASE_URL}${ENDPOINT}"
body_tmpl='{"account_id":"%s","amount":%s,"currency":"%s","transaction_type":"%s","source_ip":"%s"}'

echo "[S7] target        : ${url}"
echo "[S7] account_id    : ${ACCOUNT_ID}"
echo "[S7] amount        : ${AMOUNT} ${CURRENCY} (R02 threshold 3,000,000)"
echo "[S7] duration/intvl: ${DURATION_SEC}s / ${INTERVAL_SEC}s"
echo "[S7] dry-run       : ${DRY_RUN}"
echo

if [[ "${DRY_RUN}" == "1" ]]; then
  printf "${body_tmpl}\n" "${ACCOUNT_ID}" "${AMOUNT}" "${CURRENCY}" "${TXN_TYPE}" "${SOURCE_IP}"
  echo "[S7] dry-run: 전송하지 않고 종료."
  exit 0
fi

start_ts=$(date +%s)
sent=0; ok201=0; other=0
detected=0

while (( $(date +%s) - start_ts < DURATION_SEC )); do
  body=$(printf "${body_tmpl}" "${ACCOUNT_ID}" "${AMOUNT}" "${CURRENCY}" "${TXN_TYPE}" "${SOURCE_IP}")
  resp=$(curl -sS -o /tmp/s7_resp.$$ -w '%{http_code}' \
           -H 'Content-Type: application/json' -X POST --data "${body}" "${url}" || echo "000")
  sent=$((sent+1))
  if [[ "${resp}" == "201" ]]; then
    ok201=$((ok201+1))
    if grep -q '"fds_detected": *true' /tmp/s7_resp.$$ 2>/dev/null || grep -q '"fds_detected":true' /tmp/s7_resp.$$ 2>/dev/null; then
      detected=$((detected+1))
    fi
  else
    other=$((other+1))
    echo "  [warn] HTTP ${resp} : $(head -c 200 /tmp/s7_resp.$$ 2>/dev/null)"
  fi
  printf "\r[S7] sent=%d  201=%d  fds_detected=true:%d  non-201=%d " "${sent}" "${ok201}" "${detected}" "${other}"
  sleep "${INTERVAL_SEC}"
done
rm -f /tmp/s7_resp.$$
echo; echo
echo "[S7] 완료. 총 ${sent}건 전송 / 201 ${ok201}건 / fds_detected=true ${detected}건 / non-201 ${other}건"
echo "[S7] 다음 확인:"
echo "     - Prometheus : sum(increase(fds_detected_total{rule_id=\"R02\"}[5m]))"
echo "     - Alertmanager UI : FDSDetectionBurst = Firing → (부하 종료 5~6분 후) Resolved"
echo "     - Grafana 'Application & FDS' : R02 라인이 빨강 임계선(20) 초과"
echo "     - raw 저장 확인 : psql 로 transactions 테이블 SELECT (거래는 201 로 저장됨)"
