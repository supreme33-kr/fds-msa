# transaction-api ↔ fds-engine Internal Contract v1.0

> Status: DRAFT (G0 Design Freeze 대상)
> Owner: 이재환
> Related Ticket: P1-MSA-01
> Depends on: FDS_Network_Baseline_v2.2 (Deny: fds-engine → DB)

---

## 0. 설계 전제

`fds-engine`은 DB에 직접 접근할 수 없다 (Network Baseline Deny 정책).
따라서 이력 기반 Rule(R01, R07)에 필요한 집계값은 **transaction-api가 사전 계산**하여
`context` 필드로 전달한다. fds-engine은 완전히 stateless하게 판정만 수행한다.

---

## 1. Endpoint

| 항목 | 값 |
|---|---|
| Method | `POST` |
| URL | `http://fds-engine.<namespace>.svc.cluster.local:8001/evaluate` |
| 노출 범위 | ClusterIP 내부 전용 (외부 미노출) |
| Content-Type | `application/json` |
| Timeout | connect 1s / read 2s (transaction-api 측 설정) |

---

## 2. Request: transaction-api → fds-engine

```json
{
  "transaction_id": "b3f1c2e0-....",
  "account_id": "acc_00123",
  "amount": 1500000,
  "currency": "KRW",
  "transaction_type": "withdrawal",
  "source_ip": "203.0.113.10",
  "occurred_at": "2026-08-26T23:41:00Z",
  "received_at": "2026-08-26T23:41:00.120Z",
  "context": {
    "recent_withdrawal_count_10m": 3,
    "recent_transfer_count_1h": 0,
    "recent_transfer_sum_1h": 0
  }
}
```

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| transaction_id | string (UUID) | Y | transaction-api 생성 |
| account_id | string | Y | 계좌/사용자 식별자 |
| amount | number | Y | 거래 금액 (KRW 정수 단위) |
| currency | string | Y | ISO 4217, 기본 `KRW` |
| transaction_type | enum | Y | `withdrawal` \| `transfer` \| `deposit` |
| source_ip | string | Y | 없으면 `missing_client_ip_total` 증가 후에도 필드는 전달 (빈 문자열 허용) |
| occurred_at | string (ISO8601 UTC) | Y | R04(심야) 판정 기준 시각 |
| received_at | string (ISO8601 UTC) | Y | 서버 수신 시각 (지연 측정용) |
| context.recent_withdrawal_count_10m | int | R01 대상 시 필수 | 최근 10분 내 동일 계좌 인출 횟수 |
| context.recent_transfer_count_1h | int | R07 대상 시 필수 | 최근 1시간 내 동일 계좌 이체 건수 |
| context.recent_transfer_sum_1h | number | R07 대상 시 필수 | 최근 1시간 내 동일 계좌 이체 합산액 |

> transaction_type이 `deposit`인 경우 context는 0으로 채워서 보내거나 생략 가능 (fds-engine 쪽에서 default 0 처리).

---

## 3. Response: fds-engine → transaction-api

```json
{
  "transaction_id": "b3f1c2e0-....",
  "fds_detected": true,
  "fds_rules": [
    { "rule_id": "R01", "triggered": true, "detail": "10분 내 인출 3회 (threshold 3)" },
    { "rule_id": "R02", "triggered": false, "detail": null },
    { "rule_id": "R04", "triggered": false, "detail": null },
    { "rule_id": "R07", "triggered": false, "detail": null }
  ],
  "evaluated_at": "2026-08-26T23:41:00.180Z"
}
```

| 필드 | 타입 | 설명 |
|---|---|---|
| transaction_id | string | 요청 echo, 매칭용 |
| fds_detected | boolean | 4개 rule 중 하나라도 triggered면 true |
| fds_rules | array | **4개 rule 전부 항상 포함** (미탐지도 `triggered: false`로 명시 — 부분 응답 금지) |
| fds_rules[].rule_id | string | R01/R02/R04/R07 고정값 |
| fds_rules[].triggered | boolean | 개별 판정 결과 |
| fds_rules[].detail | string \| null | 사람이 읽을 수 있는 판정 근거, 미탐지 시 null |
| evaluated_at | string (ISO8601 UTC) | fds-engine 판정 완료 시각 |

---

## 4. Rule별 판정 기준 (초안 — 실제 threshold는 구현 시 확정)

| Rule | 필요 입력 | Stateless 여부 |
|---|---|---|
| R01 REPEAT_WITHDRAWAL | `transaction_type=withdrawal` + `context.recent_withdrawal_count_10m` | context 필요 |
| R02 HIGH_AMOUNT | `amount` | 완전 stateless |
| R04 LATE_NIGHT_HIGH_AMOUNT | `occurred_at`(시각) + `amount` | 완전 stateless |
| R07 SMALL_TRANSFER_SPLIT | `transaction_type=transfer` + `context.recent_transfer_count_1h`/`sum_1h` | context 필요 |

---

## 5. 장애/타임아웃 처리 — **결정 필요 (OPEN ISSUE)**

fds-engine이 타임아웃되거나 5xx를 반환할 경우 transaction-api의 동작을 다음 중 하나로 결정해야 함:

- **Option A (fail-open, 권장)**: 거래는 정상 저장하되 `fds_detected=null`, `fds_evaluation_skipped=true`로 기록하고 `fds_evaluation_error_total` 메트릭 증가. 거래 자체를 막지 않음 — Phase 1 목적이 "탐지"이지 "차단"이 아니므로 가용성 우선.
- **Option B (fail-closed)**: fds-engine 미응답 시 거래 자체를 거부(503). 금융권 실무에 가깝지만 Phase 1 P0 목표(가용성 중심 E2E)와 상충 가능.

> 별도 결정 없으면 **Option A로 기본 채택**하고 P1-MSA-01 티켓에 기록.

---

## 6. Health Check (참고 — Probe 작업과 연계)

fds-engine은 DB 등 외부 의존성이 없으므로 `/health` 단일 엔드포인트로 liveness/readiness 겸용.
transaction-api는 `/health`(liveness, 무의존성) / `/ready`(readiness+startupProbe, DB 커넥션 체크)로 분리.
(FDS_SECURITY_BASELINE_v2 / Probe 필수화 작업 참조)

---

## 7. Open Issues

- [ ] §5 장애 처리 정책 A/B 확정
- [ ] Rule threshold 실제 값 (R01 횟수, R02 금액, R04 시간대+금액, R07 건수/합산액) — 구현 시 확정
- [ ] `context` 계산 쿼리가 transaction-api → db01 부하에 미치는 영향 측정 (P1-MON-01 이후 확인)
