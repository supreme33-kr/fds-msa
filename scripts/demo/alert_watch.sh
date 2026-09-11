#!/usr/bin/env bash
# 발표 보조 — Alertmanager 를 폴링해서 "새 알림 발생 / 해소" 를 표시하고(배너+벨),
# 선택적으로 Slack / Discord webhook 으로 밀어준다.
#
#   ⚠️ 클러스터(Alertmanager) 설정은 전혀 바꾸지 않는다. 읽기 전용 폴링 + 클라이언트 릴레이.
#      인터넷 되는 쪽(예: Windows 노트북 Git Bash)에서 실행하면 edge01 에 인터넷이 없어도 된다.
#      v1.5 §1 상 외부 알림은 정본 범위 밖 → "발표 시연용 보조" 로만 소개한다.
#
#   기본은 k3s-hairpin 상시 알림(노드/kubelet 지표 수집 실패)은 무시하고,
#   시연 알림(이상거래 급증 / 관측 대상 다운 / 관측 알림 전달 시험)에만 반응한다.
#
# 사용:
#   ./alert_watch.sh                                   # 배너+벨만 (NodePort http://10.1.93.50:31403)
#   WEBHOOK_URL='https://discord.com/api/webhooks/...'  ./alert_watch.sh
#   WEBHOOK_URL='https://hooks.slack.com/services/...'  ./alert_watch.sh
#   WEBHOOK_URL='...' ./alert_watch.sh --test           # 테스트 메시지 1건 보내고 종료
#   AM_URL=http://localhost:9093  WATCH_HAIRPIN=1  POLL=3  ./alert_watch.sh
set -uo pipefail

AM_URL="${AM_URL:-http://10.1.93.50:31403}"
POLL="${POLL:-5}"
WATCH_HAIRPIN="${WATCH_HAIRPIN:-0}"
WEBHOOK_URL="${WEBHOOK_URL:-}"

RED=$'\e[41;97m'; GRN=$'\e[42;30m'; RST=$'\e[0m'

case "$WEBHOOK_URL" in
  *discord*) WK=discord ;;
  *slack*|*hooks.slack*) WK=slack ;;
  "") WK=none ;;
  *) WK=slack ;;   # 알 수 없으면 {"text":...} 형식 시도
esac

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

push() {  # $1 = 메시지 텍스트
  [ "$WK" = none ] && return 0
  local msg; msg="$(json_escape "$1")"
  case "$WK" in
    discord) curl -s --max-time 6 -H 'Content-Type: application/json' \
               -d "{\"username\":\"FDS 관측\",\"content\":\"${msg}\"}" "$WEBHOOK_URL" >/dev/null 2>&1 ;;
    slack)   curl -s --max-time 6 -H 'Content-Type: application/json' \
               -d "{\"text\":\"${msg}\"}" "$WEBHOOK_URL" >/dev/null 2>&1 ;;
  esac
}

snapshot() {  # 현재 active 알림의 한글명(kr), 한 줄에 하나 (정렬)
  local raw
  raw="$(curl -s --max-time 4 "${AM_URL}/api/v2/alerts?active=true" 2>/dev/null \
        | grep -o '"kr":"[^"]*"' | sed 's/.*:"//; s/"$//' | sort -u)"
  if [ "$WATCH_HAIRPIN" = 1 ]; then printf '%s\n' "$raw"
  else printf '%s\n' "$raw" | grep -v 'k3s 단일노드 한계' || true; fi
}

bell() { for _ in 1 2 3; do printf '\a'; sleep 0.25; done; }
ts()   { date '+%Y-%m-%d %H:%M:%S'; }

if [ "${1:-}" = "--test" ]; then
  [ "$WK" = none ] && { echo "WEBHOOK_URL 미설정"; exit 2; }
  echo "테스트 메시지 전송 ($WK)..."
  push "🔔 [FDS 관측] webhook 연결 테스트 · $(ts)"
  echo "완료. 채널에 메시지가 왔는지 확인하세요."
  exit 0
fi

echo "── Alertmanager 감시 시작  (${AM_URL})  ${POLL}s 간격  webhook=${WK} ──"
prev="$(snapshot)"
if [ -n "$prev" ]; then echo "  현재 발생 중:"; printf '%s\n' "$prev" | sed 's/^/    • /'
else echo "  현재 발생 중인 시연 알림 없음 (정상)"; fi
echo "──────────────────────────────────────────────────────────────────"

while true; do
  sleep "$POLL"
  cur="$(snapshot)"
  [ "$cur" = "$prev" ] && continue

  comm -13 <(printf '%s\n' "$prev") <(printf '%s\n' "$cur") | while IFS= read -r a; do
    [ -z "$a" ] && continue
    printf '\n%s  🚨  알림 발생 : %s   %s%s\n' "$RED" "$a" "$(ts)" "$RST"; bell
    push "🚨 [FDS 관측] 알림 발생: ${a} · $(ts)"
  done
  comm -23 <(printf '%s\n' "$prev") <(printf '%s\n' "$cur") | while IFS= read -r a; do
    [ -z "$a" ] && continue
    printf '\n%s  ✔   해소     : %s   %s%s\n' "$GRN" "$a" "$(ts)" "$RST"
    push "✅ [FDS 관측] 해소: ${a} · $(ts)"
  done

  prev="$cur"
done
