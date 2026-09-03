# P1-DB-03 — Migration 정식 버전관리 전환

## 이게 뭔지
"임시 스켈레톤 SQL"을 Alembic 기반 정식 버전관리 Migration으로 전환한 것.
`fds-msa` 레포의 db 관련 디렉터리(예: `db/` 또는 `transaction-api/db/`)로
그대로 복사해 쓰면 됩니다.

**2026-09-03 db01(fdsdb) 실제 스키마와 대조 완료.** `0001_initial_schema.py`는
현재 db01의 `transactions` 테이블과 1:1로 일치하도록 작성돼 있습니다
(transaction_id는 TEXT PK, fds_results 별도 테이블 없음, fds_detected는
transactions 컬럼으로 존재).

## db01(fdsdb)에 적용하는 법 — 이미 데이터 있는 DB이므로 반드시 stamp만

```bash
pip install -r requirements.txt --break-system-packages
export DATABASE_URL="postgresql+psycopg://fds_app:<비밀번호>@127.0.0.1:5432/fdsdb"

# 실행하지 말고 stamp만 — 기존 데이터 보존
alembic stamp 0001

# 확인
alembic current
```

`alembic upgrade head`를 db01에 실행하면 안 됩니다 (테이블 재생성 시도로
기존 데이터와 충돌). **완전 신규 환경**(로컬 테스트 DB 등)에서만:
```bash
alembic upgrade head
```

## 접속 시 알아둘 것 (db01 내부에서 psql/alembic 접속 시 겪었던 문제)
- `psql`은 `postgresql://` 형식만 이해함 (`+psycopg` 붙이면 파싱 실패,
  아무 에러 없이 조용히 로컬 소켓+OS계정으로 fallback해서 헷갈리는 에러남)
- `postgresql+psycopg://`는 Alembic/SQLAlchemy 전용
- `localhost`는 `::1`(IPv6)로 먼저 풀려서 pg_hba.conf의 `ident` 규칙에
  걸림 → `127.0.0.1` 사용 권장
- **pg_hba.conf에 db01 자기 자신(10.1.93.55)이 hostssl 허용 목록에 없음**
  (Worker `.105/.107/.108`, edge01 `.50`만 있음) — db01 안에서 자기
  자신에게 붙을 땐 `127.0.0.1`(scram-sha-256, host 규칙)로 우회 가능.
  이건 P1-DB-05(pg_hba.conf 최종 축소) 작업 때 의도된 건지 확인 필요한
  이슈로 별도 기록해둘 것.

## Timezone 정책 — 미확정 상태로 진행함
`received_at`, `event_time` 전부 `TIMESTAMP WITH TIME ZONE`으로 만들고
서버 기본값은 `(now() AT TIME ZONE 'utc')`로 **UTC 가정**해서 구현했습니다.
팀 Decision(UTC vs KST)이 아직 공식 확정 전이라, 확정되면:
- KST로 간다면 `server_default`만 바꾸면 됨 (컬럼 타입 자체는 안 바뀜, aware timestamp라 안전)
- transaction-api 쪽에서 실제로 UTC-aware datetime을 넣고 있는지 별도 확인 필요
- R04(심야고액) 판정 로직이 `event_time`을 어느 시간대 기준으로 "심야"를 판단하는지도 같이 확정해야 함

## 사용법
```bash
pip install -r requirements.txt --break-system-packages
export DATABASE_URL="postgresql+psycopg://fds_app:<PASSWORD>@10.1.93.55:5432/fdsdb"

# 실행 전 미리보기 (실제 DB 안 건드림)
alembic upgrade head --sql

# 기존 DB에 이미 테이블 있으면 채택만
alembic stamp 0001

# 신규 환경이면 실제 적용
alembic upgrade head

# 새 Migration 추가할 때 (모델을 models.py에서 먼저 수정한 뒤)
alembic revision --autogenerate -m "설명"
```

## 다음에 할 일 (0002 이후 후보)
- Timezone Decision 확정되면 필요 시 컬럼 보정 Migration
- `triggered_rules`를 문자열 대신 배열/JSON으로 정규화할지 여부
- pg_hba.conf 재검증(P1-DB-05, 실클러스터 확보 후) 관련해서
  role/grant 관리를 이 Migration 체계 안으로 편입할지 결정
