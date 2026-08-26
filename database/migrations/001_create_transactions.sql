-- transactions 테이블 — transaction-api/app/db.py 의 SQLAlchemy 모델과 일치시킬 것
-- PostgreSQL < 15 대비 REVOKE 포함 (FDS_SECURITY_BASELINE_v2)

CREATE TABLE IF NOT EXISTS transactions (
    transaction_id          TEXT PRIMARY KEY,
    account_id               TEXT NOT NULL,
    amount                    NUMERIC NOT NULL,
    currency                  TEXT NOT NULL DEFAULT 'KRW',
    transaction_type          TEXT NOT NULL,
    source_ip                 TEXT,
    occurred_at               TIMESTAMPTZ NOT NULL,
    received_at               TIMESTAMPTZ NOT NULL,
    fds_detected               BOOLEAN,
    fds_rules                  JSONB,
    fds_evaluation_skipped     BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_transactions_account_id ON transactions (account_id);
CREATE INDEX IF NOT EXISTS idx_transactions_account_type_time
    ON transactions (account_id, transaction_type, occurred_at);

-- PostgreSQL < 15: public 스키마 기본 CREATE 권한 제거 (Idempotent)
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
