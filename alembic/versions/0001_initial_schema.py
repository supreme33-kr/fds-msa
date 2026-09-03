"""P1-DB-03: 정식 버전관리 전환 — db01 실제 스키마 기준 Baseline

Revision ID: 0001
Revises:
Create Date: 2026-09-03

2026-09-03 db01(fdsdb)의 실제 스키마 조회 결과를 그대로 반영해
다시 작성함 (최초 버전은 UUID/fds_results 별도 테이블을 잘못 가정했었음).

[적용 방법 — db01은 반드시 아래를 따를 것]
  db01에는 이미 이 구조의 transactions 테이블이 있고 데이터가 있을 수
  있다. upgrade()를 그대로 실행(=재생성 시도)하면 안 된다.

    alembic stamp 0001

  로 "이미 이 상태다"라고 채택만 한다. 이후 스키마 변경은 0002부터
  alembic revision --autogenerate 로 이어간다.

  upgrade()는 완전 신규(로컬 테스트 등) 환경에서만 실행한다.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "transactions",
        sa.Column("transaction_id", sa.Text(), primary_key=True),
        sa.Column("account_id", sa.Text(), nullable=False),
        sa.Column("amount", sa.Numeric(), nullable=False),
        sa.Column(
            "currency",
            sa.Text(),
            nullable=False,
            server_default=sa.text("'KRW'::text"),
        ),
        sa.Column("transaction_type", sa.Text(), nullable=False),
        sa.Column("source_ip", sa.Text(), nullable=True),
        sa.Column("occurred_at", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("received_at", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("fds_detected", sa.Boolean(), nullable=True),
    )


def downgrade() -> None:
    op.drop_table("transactions")
