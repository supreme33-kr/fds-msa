"""
fds-engine — 내부 전용 Rule 평가 서비스.
외부 미노출 (ClusterIP), transaction-api에서만 TCP 8001로 호출.
DB 의존성 없음 → /health 하나로 liveness/readiness 겸용.
"""
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response
from pydantic import BaseModel, Field

from .rules import evaluate_all

app = FastAPI(title="fds-engine", version="1.0.0")

# --- Metrics (P1-MON-01 대비) ---
FDS_DETECTED_TOTAL = Counter(
    "fds_detected_total", "Rule별 탐지 건수", ["rule_id"]
)
FDS_EVALUATED_TOTAL = Counter(
    "fds_evaluated_total", "전체 평가 요청 건수"
)


class ContextPayload(BaseModel):
    recent_withdrawal_count_10m: int = 0
    recent_transfer_count_1h: int = 0
    recent_transfer_sum_1h: float = 0


class EvaluateRequest(BaseModel):
    transaction_id: str
    account_id: str
    amount: float
    currency: str = "KRW"
    transaction_type: str = Field(..., pattern="^(withdrawal|transfer|deposit)$")
    source_ip: str = ""
    occurred_at: str
    received_at: str
    context: ContextPayload = ContextPayload()


@app.get("/livez")
async def health():
    # 외부 의존성 없음 — 프로세스 응답 여부만 확인
    return {"status": "ok"}


@app.get("/readyz")
async def ready():
    # fds-engine은 외부 의존성 없음 — livez와 동일 로직, readiness probe용 별도 경로
    return {"status": "ok"}


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/evaluate")
async def evaluate(req: EvaluateRequest):
    FDS_EVALUATED_TOTAL.inc()
    try:
        rules = evaluate_all(req.model_dump())
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"evaluation error: {e}")

    for r in rules:
        if r["triggered"]:
            FDS_DETECTED_TOTAL.labels(rule_id=r["rule_id"]).inc()

    return {
        "transaction_id": req.transaction_id,
        "fds_detected": any(r["triggered"] for r in rules),
        "fds_rules": rules,
        "evaluated_at": datetime.now(timezone.utc).isoformat(),
    }
