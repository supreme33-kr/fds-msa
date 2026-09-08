"""P1-DB-01 R1 remediation: FDS 평가 결과 저장 컬럼 버전관리 편입 (schema drift 해소)

Revision ID: 0002
Revises: 0001
Create Date: 2026-09-08

2026-09-08 P1-DB-01 리뷰(R1)에서 발견된 schema drift 해소.
db01의 transactions 테이블에는 0001 Migration에 정의되지 않은
fds_rules(jsonb), fds_evaluation_skipped(boolean) 컬럼이
Alembic 버전관리 밖에서(수동 ALTER TABLE로 추정) 이미 존재함을 확인.
이 revision은 해당 컬럼을 버전관리에 편입시켜 신규(빈) DB에서도
동일한 운영 스키마가 재현되도록 한다.

[적용 방법]
  - db01(기존 데이터 있음): 컬럼이 이미 존재하므로 upgrade()를 그대로
    실행하면 "column already exists" 오류가 날 수 있음. 실행 전
    반드시 컬럼 존재 여부 확인 후 `alembic stamp 0002`로 채택할지,
    조건부 add_column으로 안전 실행할지 팀 결정 필요 (운영 fdsdb에는
    당장 실행하지 않음).
  - 신규(로컬/CI/재현 테스트) 환경: upgrade()를 그대로 실행하면
    0001 + 0002로 현재 운영 스키마와 동일한 상태가 재현됨.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0002"
down_revision: Union[str, None] = "0001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "transactions",
        sa.Column("fds_rules", postgresql.JSONB(), nullable=True),
    )
    op.add_column(
        "transactions",
        sa.Column(
            "fds_evaluation_skipped",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
    )


def downgrade() -> None:
    op.drop_column("transactions", "fds_evaluation_skipped")
    op.drop_column("transactions", "fds_rules")
