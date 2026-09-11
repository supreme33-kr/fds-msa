#!/usr/bin/env bash
# S7a / TC-APP — 합성 거래의 탐지·기록·지표 (시나리오 v1.5 §6 S7a)
#
#   합성 거래를 transaction-api 에 POST 하고, 응답의 fds_rules[] 로 "실제로 어떤 Rule 이
#   트리거됐는지"를 집계한다. 금액만 보고 "고액이면 R02" 라고 단정하지 않는다(v1.5 금지).
#   201 = 자원 생성 의미일 뿐 업무 승인·실제 송금이 아니다.
#
#   선택: --with-metrics 시 Prometheus 에서 rule_id 별 fds_detected_total 증가분을 전후 비교
#         (transaction-api/fds-engine 파드 단위 스크레이프 전제 — headless-services.yaml).
#
# 사용법:
#   BASE_URL=http://10.1.93.50 ./s7a_app_txn.sh
#   COUNT=40 AMOUNT=3500000 TXN_TYPE=withdrawal ACCOUNT_ID=SIM_s7a_001 ./s7a_app_txn.sh --with-metrics
#   DRY_RUN=1 ./s7a_app_txn.sh
#
set -uo pipefail

BASE_URL="${BASE_URL:-http://10.1.93.50}"
ENDPOINT="${ENDPOINT:-/api/v1/transactions}"
ACCOUNT_ID="${ACCOUNT_ID:-SIM_s7a_$(date +%H%M%S)}"   # 합성 식별자 (v1.5 §4.2)
AMOUNT="${AMOUNT:-3500000}"
CURRENCY="${CURRENCY:-KRW}"
TXN_TYPE="${TXN_TYPE:-withdrawal}"                     # withdrawal|transfer|deposit
SOURCE_IP="${SOURCE_IP:-203.0.113.77}"
COUNT="${COUNT:-40}"
INTERVAL_SEC="${INTERVAL_SEC:-0.5}"
DRY_RUN="${DRY_RUN:-0}"
PROM_NS="${PROM_NS:-fds}"; PROM_DEPLOY="${PROM_DEPLOY:-prometheus}"

url="${BASE_URL}${ENDPOINT}"
body_tmpl='{"account_id":"%s","amount":%s,"currency":"%s","transaction_type":"%s","source_ip":"%s"}'

promq() { kubectl -n "$PROM_NS" exec "deploy/$PROM_DEPLOY" -- wget -qO- "localhost:9090/api/v1/query?query=$1" 2>/dev/null; }
rule_increase() { promq 'sum%20by%20(rule_id)%20(increase(fds_detected_total%5B5m%5D))' \
  | sed 's/},{/}\n{/g' | grep -oE '"rule_id":"[^"]*"[^}]*"value":\[[0-9.]+,"[^"]+"\]' \
  | sed -E 's/.*"rule_id":"([^"]*)".*,"([0-9.]+)"\]/  \1 = \2/'; }

echo "[S7a] target      : ${url}"
echo "[S7a] account_id  : ${ACCOUNT_ID}  (합성)"
echo "[S7a] txn         : ${TXN_TYPE}  ${AMOUNT} ${CURRENCY}  x ${COUNT}"
echo "[S7a] 주의        : 201 = 자원 생성. 업무 승인/실제 송금 아님. 트리거 Rule 은 응답으로 판정."
echo

if [[ "$DRY_RUN" == "1" ]]; then
  printf "${body_tmpl}\n" "$ACCOUNT_ID" "$AMOUNT" "$CURRENCY" "$TXN_TYPE" "$SOURCE_IP"
  echo "[S7a] dry-run 종료."; exit 0
fi

if [[ "${1:-}" == "--with-metrics" ]]; then
  echo "[S7a] 전 지표 (rule_id 별 5m 증가분):"; rule_increase; echo
fi

sent=0; ok=0; other=0; detected=0
declare -A rt=( [R01]=0 [R02]=0 [R04]=0 [R07]=0 )
for ((i=1;i<=COUNT;i++)); do
  body=$(printf "${body_tmpl}" "$ACCOUNT_ID" "$AMOUNT" "$CURRENCY" "$TXN_TYPE" "$SOURCE_IP")
  resp=$(curl -sS -o /tmp/s7a.$$ -w '%{http_code}' -H 'Content-Type: application/json' -X POST --data "$body" "$url" || echo 000)
  sent=$((sent+1))
  if [[ "$resp" == "201" ]]; then
    ok=$((ok+1))
    grep -q '"fds_detected": *true\|"fds_detected":true' /tmp/s7a.$$ && detected=$((detected+1))
    for r in R01 R02 R04 R07; do
      grep -qE "\"rule_id\": *\"$r\", *\"triggered\": *true|\"rule_id\":\"$r\",\"triggered\":true" /tmp/s7a.$$ && rt[$r]=$(( ${rt[$r]} + 1 ))
    done
  else
    other=$((other+1)); echo "  [warn] HTTP $resp : $(head -c 160 /tmp/s7a.$$)"
  fi
  printf "\r[S7a] sent=%d 201=%d fds_detected=true:%d non-201=%d " "$sent" "$ok" "$detected" "$other"
  sleep "$INTERVAL_SEC"
done
rm -f /tmp/s7a.$$
echo; echo
echo "[S7a] 응답 기준 Rule 트리거 집계 (거래 건수와 동일시하지 않음):"
for r in R01 R02 R04 R07; do echo "  $r triggered in ${rt[$r]} / ${ok} responses"; done
echo
if [[ "${1:-}" == "--with-metrics" ]]; then
  echo "[S7a] 후 지표 (rule_id 별 5m 증가분, 약 15~30s 후 반영):"; sleep 20; rule_increase; echo
fi
echo "[S7a] 다음: transactions 테이블 raw SELECT 로 저장 확인(승인 운영 경로), Grafana 'Application & FDS' 동일 시간대."
