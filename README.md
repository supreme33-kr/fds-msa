# FDS Platform — transaction-api / fds-engine

On-Premises FDS(P1) MSA 구현. Implementation Baseline v3.1.1 기준.

## 구성

| 디렉터리 | 내용 |
|---|---|
| `transaction-api/` | Client 요청 수신, R01/R07용 context 사전 계산, fds-engine 호출, DB 저장 |
| `fds-engine/` | R01/R02/R04/R07 stateless 판정 (DB 접근 없음) |
| `kubernetes/base/` | Namespace, ServiceAccount, NetworkPolicy, Deployment, Service, ConfigMap/Secret 템플릿 |
| `database/migrations/` | PostgreSQL 스키마 |
| `docs/` | Internal API Contract |

## 로컬 실행 (Docker 없이 직접 실행 시)

```bash
# 1. PostgreSQL 준비 후 마이그레이션 적용
psql -h <db-host> -U fds_app -d fdsdb -f database/migrations/001_create_transactions.sql

# 2. fds-engine
cd fds-engine
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8001

# 3. transaction-api
cd transaction-api
pip install -r requirements.txt
export DATABASE_URL="postgresql+asyncpg://fds_app:<password>@<db-host>:5432/fdsdb"
export FDS_ENGINE_URL="http://localhost:8001/evaluate"
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

## 확인 필요 (Open Issues)

- `docs/transaction-api_fds-engine_contract_v1.0.md` §5: fail-open(Option A) 확정 여부
- Rule threshold 실제값 (`fds-engine/app/rules.py` 상단 상수 — 전부 초안)
- `kubernetes/base/networkpolicy.yaml`: monitor01 스크레이프 경로(Management VMnet 가정) 이권욱 확인 필요
- `kubernetes/base/secret.example.yaml`: fds_app 비밀번호 재발급 필요 (bash history 노출 이력)

## 상태

- [x] Interface Contract v1.0 Draft
- [x] fds-engine / transaction-api 스캐폴딩
- [x] 로컬 실행 테스트 (PostgreSQL + uvicorn, R01/R02/R04/R07/fail-open 전부 검증)
- [ ] Docker 이미지 빌드 검증
- [ ] K8s 클러스터 배포 검증
- [ ] RBAC Role/RoleBinding (필요 시)
