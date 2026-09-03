"""
FDS 프로젝트 정식 스키마 모델 (P1-DB-03)

2026-09-03 db01(fdsdb) 실제 스키마(\\d+ transactions) 대조 후 재작성함.
기존 "임시 스켈레톤 SQL"이 이미 이 구조로 만들어져 있고 데이터가 있을 수
있으므로, 이 모델/마이그레이션은 **재생성용이 아니라 채택(stamp)용**이다.
자세한 절차는 프로젝트 README 참고.

[확인된 사실]
- transaction_id는 UUID가 아니라 TEXT다 (애초 설계가 이렇게 됨).
- fds_results라는 별도 테이블은 존재하지 않는다. fds_detected가
  transactions 테이블 안에 컬럼으로 직접 들어가 있다.
- R01/R02/R04/R07 중 어떤 룰이 걸렸는지(triggered_rules)는 현재
  스키마에 저장 컬럼이 없다 — fail-open 여부도 마찬가지. 필요하면
  0002 이후 Migration으로 추가할지 팀 결정 필요.
- occurred_at(이벤트 발생 시각, R04 심야고액 판정 기준)과
  received_at(서버 수신 시각)이 분리돼 있다 — 기존에 "event_time"으로
  불렀던 것이 실제로는 occurred_at 컬럼이다.

[미확인 — 확인 필요]
- transaction_id가 실제 PRIMARY KEY인지 (\\d+ 출력에서 제약조건/인덱스
  섹션이 잘려서 안 보임 — `\\d transactions` 로 재확인 권장)
- occurred_at / received_at에 인덱스가 있는지 (R04 성능에 영향)
- Timezone 정책: 컬럼 자체는 이미 timestamptz라 UTC/KST 어느 쪽으로
  정책이 정해지든 값(aware datetime) 자체는 안전하다. 다만 애플리케이션이
  실제로 어느 시간대로 넣고 있는지는 코드 확인 필요(이 Migration의 범위 밖).
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, Numeric, Text, text
from sqlalchemy.dialects.postgresql import TIMESTAMP
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class Transaction(Base):
    """거래 원본 + FDS 판정 결과 (fds_detected가 같은 테이블에 있음)."""

    __tablename__ = "transactions"

    transaction_id: Mapped[str] = mapped_column(Text, primary_key=True)
    account_id: Mapped[str] = mapped_column(Text, nullable=False)
    amount: Mapped[float] = mapped_column(Numeric, nullable=False)
    currency: Mapped[str] = mapped_column(
        Text, nullable=False, server_default=text("'KRW'::text")
    )
    transaction_type: Mapped[str] = mapped_column(Text, nullable=False)
    source_ip: Mapped[str | None] = mapped_column(Text, nullable=True)

    # 이벤트 발생 시각 — R04(심야고액) 판정 기준. timestamptz라 시간대
    # 자체는 안전하게 보관되지만, 정책(UTC/KST) 확정 전까지는 애플리케이션이
    # 실제로 무엇을 넣고 있는지 별도 확인 필요.
    occurred_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), nullable=False
    )
    received_at: Mapped[datetime] = mapped_column(
        TIMESTAMP(timezone=True), nullable=False
    )

    fds_detected: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
