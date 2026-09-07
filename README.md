# FDS Platform — transaction-api / fds-engine
On-Premises FDS(P1) MSA 구현. Implementation Baseline v3.1.1 기준 작성, 이후 프로젝트 baseline은 v3.1.17까지 갱신됨 (본 문서는 앱 구조 설명용으로 유지).

## 구성
| 디렉터리 | 내용 |
|---|---|
| `transaction-api/` | Client 요청 수신, R01/R07용 context 사전 계산, fds-engine 호출, DB 저장 |
| `fds-engine/` | R01/R02/R04/R07 stateless 판정 (DB 접근 없음) |
| `kubernetes/base/` | Namespace, ServiceAccount, NetworkPolicy, Deployment, Service, ConfigMap/Secret 템플릿 |
| `database/migrations/` | PostgreSQL 스키마 (현재는 Alembic으로 정식 버전관리 전환됨, P1-DB-03 완료) |
| `docs/` | Internal API Contract |
| `docs/evidence/` | 티켓별 Evidence 기록 (P1-DB-01 등) |

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
- `kubernetes/base/networkpolicy.yaml`: monitor01 스크레이프 경로(Management VMnet 가정) 이권욱 확인 필요 (ICR-D-NET-01-01 진행 중, End Date TBD)
- db01 pg_hba.conf에 db01 자기 자신(10.1.93.55)이 hostssl 허용 목록에서 빠져있음 — P1-DB-05 때 의도된 설계인지 이권욱 확인 필요
- `fds_rules` 컬럼에 룰 평가 결과는 저장되나, `fail_open` 여부를 별도로 저장하는 컬럼은 없음 — 0002 Migration 필요 여부 팀 결정 대기

## 보안 조치 이력
- 2026-09-07: `fds_app` 비밀번호가 bash history에 노출된 이력이 확인되어 재발급 완료. `transaction-api-secret` 갱신 및 재배포 후 정상 동작 확인(Evidence: `docs/evidence/P1-DB-01/`).
- 향후 비밀번호 등 민감값은 터미널에 직접 echo/print하지 않고, 변수 또는 별도 파일로만 다루는 것을 권장.

## 상태
- [x] Interface Contract v1.0 Draft
- [x] fds-engine / transaction-api 스캐폴딩
- [x] 로컬 실행 테스트 (PostgreSQL + uvicorn, R01/R02/R04/R07/fail-open 전부 검증)
- [x] Docker 이미지 빌드 검증 (Harbor CI/CD `build-scan-push` 파이프라인 정상 동작 확인, 2026-09-07)
- [x] K8s 클러스터 배포 검증 (edge01 임시 k3s 환경 기준, `fds` namespace에 3 replica 정상 배포·검증 완료. 단, 실제 P1-K8S-01(3CP+3Worker) 클러스터에서는 재검증 필요)
- [ ] RBAC Role/RoleBinding (필요 시)
