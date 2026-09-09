# S7a / S7b / S8 관측 스택 배포·시연 Runbook (v1.5 정렬)

- 작성일: 2026-09-09
- 담당: 이재환 (Application / Data / Monitoring / QA — Baseline v3.1.1 §3)
- 대상 저장소: `fds-msa` (구현 코드). 정본 저장소는 담당자 확인 — v1.5 §3 에 `321Team/fds-msa` 404 언급.
- 대상 시나리오: `FDS_Security_Demo_Scenarios_v1.5.md` §6 S7a·S7b·S8, §7 MON-CHECK
- 대상 환경: **E-K3S** — edge01 임시 단일 노드 k3s (`fds` / `monitoring-api` / `monitoring-node` ns)
- 이 문서는 배포·시연·증적 수집 절차. PR 리뷰 표기·판정은 CLAUDE.md 리뷰 규칙 전용 — 이 문서 범위 아님.

> ⚠️ E-K3S 결과는 **임시 실증**이다. Gate/티켓 Done, 정본(E-CANON) Runtime PASS 로 승격하지 않는다.
> 정본은 Namespace(`fds-app`/`monitoring-api`/`monitoring-node`)·Calico HEP/GNP·edge→Worker NodePort
> 경로가 다르다. 아래 "확인 항목"은 실행 전 전부 `NOT RUN`.

---

## 0. 무엇을 배포/수정했나

| 항목 | 파일 | 내용 |
|---|---|---|
| **A1** Alertmanager 화면 수신 | `alertmanager-config.yaml` | route(group_by)+inhibit_rules+`screen-only` receiver. 외부 integration 없음(메일/SMS/webhook). [BL] §11.2 |
| **A2** alert rules (core) | `alert-rules.yaml` | `fds-core-observability`: `NodeExporterDown`·`KubeletScrapeDownK3s`(info)·`TargetDown` |
| A2 optional (**E-CANON 전용**) | `alert-rules-optional.yaml` | `fds-optional-hardening`: `FDSDetectionBurst` 등 — v1.5 §1 "선택적 고도화 후보". **E-K3S 에는 적용 안 함**(ClusterIP 라운드로빈 상시 오탐). prometheus volume 은 `optional: true` |
| **S7b** P0 Test Alert | `p0-test-alert.yaml` | `FDSMonitoringPipelineTest` — 기본 비활성(`vector(1)==0`). 시연 시 `s7b_test_alert.sh` 가 `==1`로 전환 |
| **A3** Grafana 3 뷰 + PVC | `grafana.yaml`, `grafana-dashboards.yaml` | emptyDir→PVC `grafana-data`(local-path 1Gi). `Application & FDS` / `Kubernetes Workload` / **`Node & Monitoring Health`** |
| **A4** kubelet scrape | `prometheus.yaml`, `prometheus-rbac.yaml`, `allow-prometheus-egress-kubelet.yaml` | `kubelet`/`kubelet-cadvisor` static job + SA `prometheus` + ClusterRole `nodes/metrics` + egress NP. `--web.enable-lifecycle` |
| **스크레이프 (E-K3S)** | `prometheus.yaml` | transaction-api/fds-engine = **ClusterIP Service** 스크레이프. 파드 IP 직결은 E-K3S 에서 "No route to host"(node-exporter/kubelet 과 동일 계열). 라운드로빈으로 `fds-optional-hardening` 그룹의 rate/increase 는 E-K3S 에서 신뢰 불가 — 정직 발표. `headless-services.yaml` 는 **E-CANON 전환용**으로 유지 |
| A2 보조 | `kube-state-metrics.yaml` | `--metric-labels-allowlist=pods=[app],deployments=[app]` |

**손대지 않은 것:** A5 monitor01 Watchdog(IF-06B `BLOCKED`, 범위 밖), node-exporter/kubelet DOWN
(k3s hairpin — 전용 info 룰로 분리, 실 6노드에서 정석). 거래정지/`status` 컬럼/4xx — 없음.

---

## 1. 배포 (edge01)

```bash
cd fds-msa
kubectl apply -f kubernetes/monitoring/prometheus-rbac.yaml
# headless-services.yaml 는 E-CANON 전환용 — E-K3S 배포에는 불필요(적용해도 무해)
kubectl apply -f kubernetes/monitoring/alertmanager-config.yaml \
  -f kubernetes/monitoring/alert-rules.yaml \
  -f kubernetes/monitoring/p0-test-alert.yaml \
  -f kubernetes/monitoring/prometheus.yaml \
  -f kubernetes/monitoring/grafana-dashboards.yaml \
  -f kubernetes/monitoring/grafana.yaml \
  -f kubernetes/monitoring/kube-state-metrics.yaml \
  -f kubernetes/monitoring/allow-prometheus-egress-kubelet.yaml
kubectl -n fds rollout restart deploy/prometheus deploy/grafana
kubectl -n monitoring-api rollout restart deploy/kube-state-metrics
```

### 1.1 배포 확인

```bash
kubectl -n fds get pvc grafana-data                              # Bound
kubectl -n fds exec deploy/prometheus -- wget -qO- localhost:9090/api/v1/rules | grep -o '"name":"[^"]*"'
kubectl -n fds exec deploy/prometheus -- wget -qO- 'localhost:9090/api/v1/query?query=up%7Bjob%3D~%22transaction-api%7Cfds-engine%22%7D'
#   → E-K3S: 각 job ClusterIP instance 1, up=1
```

| 확인 | 기대 | 결과 |
|---|---|---|
| grafana-data PVC Bound | Bound | `NOT RUN` |
| transaction-api/fds-engine `up` | 1 (ClusterIP) | `NOT RUN` |
| 룰 그룹 3개 로드 | p0-test + core + optional-hardening | `NOT RUN` |
| kubelet 타깃 | E-K3S 에선 down (hairpin, 예상) | `NOT RUN` |
| Grafana FDS 폴더 뷰 3개 | provisioned | `NOT RUN` |

---

## 2. S7a — 합성 거래 탐지·기록·지표

```bash
BASE_URL=http://10.1.93.50 COUNT=40 ./scripts/demo/s7a_app_txn.sh --with-metrics
```

- 트리거된 Rule 은 **응답 `fds_rules[].triggered`** 로 집계한다. 금액만 보고 R02 라고 단정하지 않는다.
- `201` = 자원 생성. 업무 승인·실제 송금 아님.
- 저장 확인은 승인 운영 경로에서 `psql` raw SELECT (합성 계정). Grafana `Application & FDS` 동일 시간대.

| 확인 | 기대 | 결과 |
|---|---|---|
| POST 응답 | 201 (전건) | `NOT RUN` |
| 응답 fds_rules 트리거 집계 | fixture 에 맞는 rule_id | `NOT RUN` |
| transactions 저장 (raw SELECT) | 저장됨 | `NOT RUN` |
| rule_id 별 5m 증가분 | E-K3S 는 라운드로빈 노이즈 (참고만) | `NOT RUN` |

---

## 3. S7b — P0 Test Alert 전이 (P1-MON-01 AC11)

```bash
./scripts/demo/s7b_test_alert.sh demo     # fire → Alertmanager 수신 → clear → resolved
```

- `FDSMonitoringPipelineTest` : `vector(1)==1` fire → `vector(1)==0` clear. `vector(0)` 단독 안 씀.
- 앱 지표·스크레이프 토폴로지와 **독립**. 전달 경로(Prometheus→Alertmanager)만 검증.
- 종료 시 규칙은 기본(비활성) 상태로 자동 복구.

| 확인 | 기대 | 결과 |
|---|---|---|
| Prometheus rule firing | firing | `NOT RUN` |
| Alertmanager 동일 labels 수신 | 수신 | `NOT RUN` |
| clear 후 Prometheus inactive + AM active 해제 | resolved | `NOT RUN` |
| 규칙 원상복구 | 비활성 | `NOT RUN` |

---

## 4. S8 — 관측 신뢰성 (타깃 다운) · **선택 항목**

```bash
DOWN_SEC=120 ./scripts/demo/s8_target_down.sh
```

- `kube-state-metrics` 0 replica → `up==0` → `TargetDown` firing → 복구 → resolved.
- 타깃은 static_config 라 discovery 에서 사라지지 않음(`up=0`, 시계열 부재 아님). Pod/Service 삭제 시험과 구분.
- node-exporter/kubelet 은 S8 대상 아님(k3s hairpin, 전용 info 룰).
- **실사례 인용**: dns02 `.53` OFF 로 precheck 6/6 timeout FAIL → 재기동 PASS ([GH-F], 읽어서 인용만).

| 확인 | 기대 | 결과 |
|---|---|---|
| ksm scale 0 → up==0 | 0 | `NOT RUN` |
| TargetDown firing (for 1m) | firing | `NOT RUN` |
| 복구 → resolved | resolved | `NOT RUN` |

---

## 5. 한 번에 캡처

```bash
BASE_URL=http://10.1.93.50 ./scripts/demo/run_capture.sh          # S7a + S7b + S8
BASE_URL=http://10.1.93.50 SKIP_S8=1 ./scripts/demo/run_capture.sh # S8 생략
```
→ `docs/evidence/_local/s7s8_<ts>/` 에 `REPORT.md` · `capture.html` · raw 로그.

---

## 6. 잔여 위험 / 후속

- **E-K3S 한정.** 실 6-Node(E-CANON, P1-K8S-01 Gate 0 / Bootstrap HOLD) 이관 시 전면 재검증:
  kubelet 타깃(hairpin 해소)·node-exporter 정석·egress NP·정본 Namespace/Calico.
- **`fds-optional-hardening` 그룹** — v1.5 §1 "선택적 고도화 후보". 임계값 미확정. 발표에서 P0 로 소개 금지.
- **CI** — 이 저장소의 실행 근거는 이번 범위에서 미확보. "모든 Private repo 가 CI 불가"로 일반화하지 않는다.
- **A5 monitor01 Watchdog** IF-06B `BLOCKED` — S9 범위 밖.
- 시연 캡처는 합성 데이터만. credential 원문 금지. `docs/evidence/_local/` 는 `.gitignore`.
- 정본 저장소·0002 Migration 최신 병합/운영 적용 상태 — 담당자 확인 (v1.5 §3).

---

## 7. 제출 (사람이 수행)

1. `feature/p1-mon-s7-s8-observability` push 후 PR 생성. 정본 저장소 대상은 담당자와 확인.
2. 독립 Reviewer 지정 — 작성자(이재환)와 같은 사람 불가.
3. 리뷰 진행·판정·표기는 CLAUDE.md 리뷰 규칙 — 이 문서 범위 아님.
4. 각 TC 실행은 `FDS_Security_Demo_Run_Record_v1.0.md` 복사해 Run Record 작성 (v1.5 §9).
