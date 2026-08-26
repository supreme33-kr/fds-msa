"""
FDS Rule Evaluation Logic — stateless.

설계 원칙 (FDS_Network_Baseline_v2.2 Deny: fds-engine → DB):
  fds-engine은 DB에 직접 접근하지 않는다. R01/R07처럼 이력이 필요한 Rule은
  transaction-api가 사전 계산한 `context` 값을 그대로 사용해 판정만 수행한다.

Threshold는 전부 초안값이며 실제 운영값은 팀 논의 후 확정 필요 (Open Issue).
"""
from datetime import datetime, timezone

# --- Threshold (초안 — 확정 필요) ---
R01_WITHDRAWAL_COUNT_THRESHOLD = 3      # 10분 내 인출 3회 이상
R02_HIGH_AMOUNT_THRESHOLD = 3_000_000   # 300만원 이상 (KRW)
R04_LATE_NIGHT_START_HOUR = 23          # 23:00 ~ 06:00
R04_LATE_NIGHT_END_HOUR = 6
R04_LATE_NIGHT_AMOUNT_THRESHOLD = 1_000_000  # 100만원 이상
R07_TRANSFER_COUNT_THRESHOLD = 3        # 1시간 내 3건 이상
R07_TRANSFER_SUM_THRESHOLD = 2_000_000  # 1시간 합산 200만원 이상


def evaluate_r01(transaction_type: str, context: dict) -> tuple[bool, str | None]:
    if transaction_type != "withdrawal":
        return False, None
    count = context.get("recent_withdrawal_count_10m", 0)
    if count >= R01_WITHDRAWAL_COUNT_THRESHOLD:
        return True, f"10분 내 인출 {count}회 (threshold {R01_WITHDRAWAL_COUNT_THRESHOLD})"
    return False, None


def evaluate_r02(amount: float) -> tuple[bool, str | None]:
    if amount >= R02_HIGH_AMOUNT_THRESHOLD:
        return True, f"고액 거래 {amount:,.0f}원 (threshold {R02_HIGH_AMOUNT_THRESHOLD:,}원)"
    return False, None


def evaluate_r04(occurred_at: datetime, amount: float) -> tuple[bool, str | None]:
    hour = occurred_at.astimezone(timezone.utc).hour
    is_late_night = hour >= R04_LATE_NIGHT_START_HOUR or hour < R04_LATE_NIGHT_END_HOUR
    if is_late_night and amount >= R04_LATE_NIGHT_AMOUNT_THRESHOLD:
        return True, f"심야({hour:02d}시) 고액 거래 {amount:,.0f}원"
    return False, None


def evaluate_r07(transaction_type: str, context: dict) -> tuple[bool, str | None]:
    if transaction_type != "transfer":
        return False, None
    count = context.get("recent_transfer_count_1h", 0)
    total = context.get("recent_transfer_sum_1h", 0)
    if count >= R07_TRANSFER_COUNT_THRESHOLD and total >= R07_TRANSFER_SUM_THRESHOLD:
        return True, f"1시간 내 소액 분산 이체 {count}건 / 합산 {total:,.0f}원"
    return False, None


def evaluate_all(payload: dict) -> list[dict]:
    """payload: transaction-api가 보낸 요청 본문 (Contract v1.0 Request Schema)."""
    transaction_type = payload["transaction_type"]
    amount = payload["amount"]
    occurred_at = datetime.fromisoformat(payload["occurred_at"].replace("Z", "+00:00"))
    context = payload.get("context") or {}

    r01_triggered, r01_detail = evaluate_r01(transaction_type, context)
    r02_triggered, r02_detail = evaluate_r02(amount)
    r04_triggered, r04_detail = evaluate_r04(occurred_at, amount)
    r07_triggered, r07_detail = evaluate_r07(transaction_type, context)

    return [
        {"rule_id": "R01", "triggered": r01_triggered, "detail": r01_detail},
        {"rule_id": "R02", "triggered": r02_triggered, "detail": r02_detail},
        {"rule_id": "R04", "triggered": r04_triggered, "detail": r04_detail},
        {"rule_id": "R07", "triggered": r07_triggered, "detail": r07_detail},
    ]
