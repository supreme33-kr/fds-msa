"""
Contract v1.0 §5 Option A(fail-open) 채택:
fds-engine 타임아웃/장애 시에도 거래는 정상 저장하고,
fds_detected=None, fds_evaluation_skipped=True로 기록한다.
"""
import os
import logging

import httpx
from prometheus_client import Counter

logger = logging.getLogger("fds_client")

FDS_ENGINE_URL = os.environ.get(
    "FDS_ENGINE_URL", "http://fds-engine:8001/evaluate"
)
CONNECT_TIMEOUT = 1.0
READ_TIMEOUT = 2.0

FDS_EVALUATION_ERROR_TOTAL = Counter(
    "fds_evaluation_error_total", "fds-engine 호출 실패 건수"
)


async def call_fds_engine(payload: dict) -> dict | None:
    """성공 시 fds-engine 응답 dict, 실패 시 None (fail-open)."""
    timeout = httpx.Timeout(connect=CONNECT_TIMEOUT, read=READ_TIMEOUT, write=READ_TIMEOUT, pool=READ_TIMEOUT)
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(FDS_ENGINE_URL, json=payload)
            resp.raise_for_status()
            return resp.json()
    except (httpx.TimeoutException, httpx.HTTPError) as e:
        FDS_EVALUATION_ERROR_TOTAL.inc()
        logger.warning("fds-engine call failed, failing open: %s", e)
        return None
