import uuid
import logging
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Response, status
from pydantic import BaseModel, Field
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response as StarletteResponse

from .db import async_session, db_ping, transactions
from .context import build_context
from .fds_client import call_fds_engine

logger = logging.getLogger("transaction-api")

app = FastAPI(title="transaction-api", version="1.0.0")

# --- Metrics (Baseline §11 참조) ---
TRANSACTION_SAVE_SUCCESS_TOTAL = Counter("transaction_save_success_total", "저장 성공 건수")
TRANSACTION_SAVE_FAILURE_TOTAL = Counter("transaction_save_failure_total", "저장 실패 건수")
MISSING_CLIENT_IP_TOTAL = Counter("missing_client_ip_total", "source_ip 누락 건수")


class TransactionRequest(BaseModel):
    account_id: str
    amount: float
    currency: str = "KRW"
    transaction_type: str = Field(..., pattern="^(withdrawal|transfer|deposit)$")
    source_ip: str | None = None
    occurred_at: str | None = None  # 없으면 서버 시각 사용


# --- Health / Readiness / Startup ---
# liveness: 외부 호출 없이 프로세스 응답 여부만 확인
@app.get("/health")
async def health():
    return {"status": "ok"}


# readiness + startupProbe 공용: 실제 DB 커넥션 확인
@app.get("/ready")
async def ready(response: Response):
    try:
        await db_ping()
        return {"status": "ready"}
    except Exception as e:
        logger.error("readiness check failed: %s", e)
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "not ready"}


@app.get("/metrics")
async def metrics():
    return StarletteResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/api/v1/transactions", status_code=201)
async def create_transaction(req: TransactionRequest):
    transaction_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    occurred_at = (
        datetime.fromisoformat(req.occurred_at.replace("Z", "+00:00"))
        if req.occurred_at else now
    )

    if not req.source_ip:
        MISSING_CLIENT_IP_TOTAL.inc()

    async with async_session() as session:
        # 1) 이력 기반 Rule용 context 사전 계산 (fds-engine은 DB 접근 불가)
        context = await build_context(session, req.account_id, req.transaction_type)

        # 2) fds-engine 호출 (fail-open)
        fds_payload = {
            "transaction_id": transaction_id,
            "account_id": req.account_id,
            "amount": req.amount,
            "currency": req.currency,
            "transaction_type": req.transaction_type,
            "source_ip": req.source_ip or "",
            "occurred_at": occurred_at.isoformat(),
            "received_at": now.isoformat(),
            "context": context,
        }
        fds_result = await call_fds_engine(fds_payload)

        fds_detected = fds_result["fds_detected"] if fds_result else None
        fds_rules = fds_result["fds_rules"] if fds_result else None
        fds_evaluation_skipped = fds_result is None

        # 3) Transaction + FDS 결과 저장
        try:
            await session.execute(
                transactions.insert().values(
                    transaction_id=transaction_id,
                    account_id=req.account_id,
                    amount=req.amount,
                    currency=req.currency,
                    transaction_type=req.transaction_type,
                    source_ip=req.source_ip,
                    occurred_at=occurred_at,
                    received_at=now,
                    fds_detected=fds_detected,
                    fds_rules=fds_rules,
                    fds_evaluation_skipped=fds_evaluation_skipped,
                )
            )
            await session.commit()
            TRANSACTION_SAVE_SUCCESS_TOTAL.inc()
        except Exception as e:
            await session.rollback()
            TRANSACTION_SAVE_FAILURE_TOTAL.inc()
            logger.error("transaction save failed: %s", e)
            raise HTTPException(status_code=500, detail="transaction save failed")

    return {
        "transaction_id": transaction_id,
        "fds_detected": fds_detected,
        "fds_rules": fds_rules,
        "fds_evaluation_skipped": fds_evaluation_skipped,
    }
