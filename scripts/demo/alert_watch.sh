#!/usr/bin/env bash
# 발표 보조 — Alertmanager 를 폴링해서 "새 알림 발생 / 해소" 를 큰 배너 + 터미널 벨로 표시.
#
#   클러스터 설정을 전혀 바꾸지 않는다(읽기 전용 폴링). 인터넷 불필요. 무료.
#   Alertmanager UI/Grafana 옆에 이 터미널 창을 하나 띄워두면, demo_live.sh 가 알림을 발생시킬 때
#   여기서 "🚨 이상거래 급증 (고액거래 R02) 🚨" 배너가 뜨고 삐- 소리가 난다.
#
#   기본은 k3s-hairpin 상시 알림(노드/kubelet 지표 수집 실패)은 무시하고,
#   시연 알림(이상거래 급증 / 관측 대상 다운 / 관측 알림 전달 시험)에만 반응한다.
#
# 사용:
#   ./alert_watch.sh                                  # NodePort (http://10.1.93.50:31403)
#   AM_URL=http://localhost:9093 ./alert_watch.sh     # port-forward
#   WATCH_HAIRPIN=1 ./alert_watch.sh                  # hairpin 상시 알림도 표시
#   POLL=3 ./alert_watch.sh
set -uo pipefail

AM_URL="${AM_URL:-http://10.1.93.50:31403}"
POLL="${POLL:-5}"
WATCH_HAIRPIN="${WATCH_HAIRPIN:-0}"

RED=$'\e[41;97m'; GRN=$'\e[42;30m'; DIM=$'\e[2m'; RST=$'\e[0m'

snapshot() {  # 현재 발생 중(active) 알림의 한글명(kr) 목록, 한 줄에 하나 (정렬)
  local raw
  raw="$(curl -s --max-time 4 "${AM_URL}/api/v2/alerts?active=true" 2>/dev/null \
        | grep -o '"kr":"[^"]*"' | sed 's/.*:"//; s/"$//' | sort -u)"
  if [ "$WATCH_HAIRPIN" = 1 ]; then
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$raw" | grep -v 'k3s 단일노드 한계' || true
  fi
}

bell() { for _ in 1 2 3; do printf '\a'; sleep 0.25; done; }

echo "── Alertmanager 감시 시작  (${AM_URL})  ${POLL}s 간격 ─────────────"
prev="$(snapshot)"
if [ -n "$prev" ]; then
  echo "  현재 발생 중:"; printf '%s\n' "$prev" | sed 's/^/    • /'
else
  echo "  현재 발생 중인 시연 알림 없음 (정상)"
fi
echo "────────────────────────────────────────────────────────────────"

while true; do
  sleep "$POLL"
  cur="$(snapshot)"
  [ "$cur" = "$prev" ] && continue

  # 새로 발생
  comm -13 <(printf '%s\n' "$prev") <(printf '%s\n' "$cur") | while IFS= read -r a; do
    [ -z "$a" ] && continue
    printf '\n%s  🚨  알림 발생 : %s   %s%s\n' "$RED" "$a" "$(date '+%m-%d %H:%M:%S')" "$RST"
    bell
  done
  # 해소
  comm -23 <(printf '%s\n' "$prev") <(printf '%s\n' "$cur") | while IFS= read -r a; do
    [ -z "$a" ] && continue
    printf '\n%s  ✔   해소     : %s   %s%s\n' "$GRN" "$a" "$(date '+%m-%d %H:%M:%S')" "$RST"
  done

  prev="$cur"
done
