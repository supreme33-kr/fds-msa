"""
fds-engine이 DB에 접근할 수 없으므로(Deny 정책), 이력 기반 Rule(R01/R07)에
필요한 집계값을 transaction-api가 여기서 미리 계산해 context로 전달한다.
"""
from datetime import datetime, timedelta, timezone

from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from .db import transactions


async def build_context(session: AsyncSession, account_id: str, transaction_type: str) -> dict:
    now = datetime.now(timezone.utc)
    context = {
        "recent_withdrawal_count_10m": 0,
        "recent_transfer_count_1h": 0,
        "recent_transfer_sum_1h": 0,
    }

    if transaction_type == "withdrawal":
        since = now - timedelta(minutes=10)
        stmt = select(func.count()).select_from(transactions).where(
            transactions.c.account_id == account_id,
            transactions.c.transaction_type == "withdrawal",
            transactions.c.occurred_at >= since,
        )
        result = await session.execute(stmt)
        context["recent_withdrawal_count_10m"] = result.scalar_one()

    elif transaction_type == "transfer":
        since = now - timedelta(hours=1)
        stmt = select(
            func.count(), func.coalesce(func.sum(transactions.c.amount), 0)
        ).select_from(transactions).where(
            transactions.c.account_id == account_id,
            transactions.c.transaction_type == "transfer",
            transactions.c.occurred_at >= since,
        )
        result = await session.execute(stmt)
        count, total = result.one()
        context["recent_transfer_count_1h"] = count
        context["recent_transfer_sum_1h"] = float(total)

    return context
