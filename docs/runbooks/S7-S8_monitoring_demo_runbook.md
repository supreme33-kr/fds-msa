# S7 / S8 관측 스택 배포·시연 Runbook

- 작성일: 2026-09-09
- 담당: 이재환 (Application / Data / Monitoring / QA — Baseline v3.1.1 §3)
- 대상 저장소: `321Team/fds-msa` (IMPLEMENTATION_CODE), 기준 HEAD `dc674f0` (main)
- 대상 시나리오: `FDS_보안시연_시나리오_v1.4_PR현황반영.md` §2 A1~A4 · §3 S7 · §3 S8
- 대상 환경: **edge01 임시 k3s (단일 노드, `fds` / `monitoring-api` / `monitoring-node` ns)**
- 구현·시연: 이재환 (App/Data/Monitoring/QA)
- 이 문서는 배포·시연·증적 수집 절차. GitHub PR 리뷰 표기(AI 사용/AI 활용/사람 확인/최종 판정)는 리뷰 초안에만 적용 — 이 문서 범위 아님(CLAUDE.md §2).

> ⚠️ 이 Runbook의 실행 결과는 아직 아무것도 채워지지 않았다. 아래 "확인 항목"은 전부
> `NOT RUN`. 실행한 사람이 로그를 붙이고 표기를 갱신한다. CI는 GitHub Free Private로
> `NOT RUN` (보상통제: CR 브랜치 + PR 리뷰 + 불변 SHA + main 직접 push 금지).

---

## 0. 무엇을 추가했나 (신규 통제 아님 — 이미 P0인데 미배포)

| 항목 | 파일 | 변경 |
|---|---|---|
| **A1** Alertmanager 화면 수신 1개 | `kubernetes/monitoring/alertmanager-config.yaml` | 빈 receiver → route(group_by alertname/severity) + inhibit_rules + `screen-only` receiver(integration 없음 = UI에만). 메일/SMS/메신저 없음([BL] §11.2, IF-24 RETIRED) |
| **A2** Prometheus alert rules | `kubernetes/monitoring/alert-rules.yaml` | `NodeExporterDown` 유지 + `TargetDown` · `FDSDetectionBurst`(R02) · `FDSDetectionBurstAnyRule`(info) · `UnexpectedPodInFdsNs` 추가. **모든 threshold = NOT VERIFIED** |
| **A3** Grafana 3 대시보드 + PVC | `kubernetes/monitoring/grafana.yaml`, `grafana-dashboards.yaml` | `data` emptyDir → PVC `grafana-data`(local-path 1Gi). dashboard provisioning provider + `Application & FDS` / `Kubernetes Workload` / `Target Health` 3종 |
| **A4** kubelet(10250) scrape | `kubernetes/monitoring/prometheus.yaml`, `prometheus-rbac.yaml`, `allow-prometheus-egress-kubelet.yaml` | `kubelet` · `kubelet-cadvisor` static job + SA `prometheus` + ClusterRole `nodes/metrics` + egress NetworkPolicy(.50:10250). `--web.enable-lifecycle` 추가 |
| A2 보조 | `kubernetes/monitoring/kube-state-metrics.yaml` | `--metric-labels-allowlist=pods=[app],deployments=[app]` (UnexpectedPodInFdsNs 룰이 `kube_pod_labels{label_app=...}` 사용) |

**손대지 않은 것:** A5 monitor01 외부 Watchdog(IF-06B `BLOCKED` — 경로 이슈, 이재환 범위 밖),
A6 node-exporter DOWN(k3s hairpin — §6 탐지 한계로 정직하게 발표, 실 6노드에서 해소).
거래정지/`status` 컬럼/4xx 차단 — 없음(팀 확정).

임계값이 `NOT VERIFIED`인 이유: 베이스라인 트래픽을 관측한 적이 없다. 시연에서 관측한
정상 rate를 기록한 뒤 팀이 확정한다. 지금 값(FDSDetectionBurst `>20/5m`,
UnexpectedPodInFdsNs `정상 파드 9개 기준`)은 시연이 "동작"함을 보이기 위한 임시값이다.

---

## 1. 배포 (edge01, kubectl 접근 가능한 위치에서)

```bash
cd fds-msa

# 1) RBAC / SA 먼저 (Prometheus 재기동 전에 있어야 kubelet 스크레이프 인증됨)
kubectl apply -f kubernetes/monitoring/prometheus-rbac.yaml

# 2) ConfigMap (Alertmanager / Prometheus / rules / Grafana provisioning)
kubectl apply -f kubernetes/monitoring/alertmanager-config.yaml
kubectl apply -f kubernetes/monitoring/alert-rules.yaml
kubectl apply -f kubernetes/monitoring/prometheus.yaml
kubectl apply -f kubernetes/monitoring/grafana-dashboards.yaml
kubectl apply -f kubernetes/monitoring/grafana.yaml
kubectl apply -f kubernetes/monitoring/kube-state-metrics.yaml

# 3) NetworkPolicy (fds ns egress → kubelet)
kubectl apply -f kubernetes/monitoring/allow-prometheus-egress-kubelet.yaml

# 4) 재기동 — Prometheus Deployment(SA/flag 변경), Grafana(PVC/마운트 변경), ksm(args 변경)
kubectl -n fds rollout restart deploy/prometheus deploy/grafana
kubectl -n monitoring-api rollout restart deploy/kube-state-metrics

# Alertmanager 는 config 파일 자동 reload → restart 불필요.
# (ConfigMap만 바꿨고 Deployment 는 안 바꿨다면 Prometheus 도
#  kubectl -n fds exec deploy/prometheus -- wget -qO- --post-data='' http://localhost:9090/-/reload  로 대체 가능)
```

### 1.1 배포 확인

```bash
kubectl -n fds get pod -l 'app in (prometheus,grafana,alertmanager)'
kubectl -n fds get pvc grafana-data                     # STATUS=Bound 여야 함
kubectl -n monitoring-api get pod -l app=kube-state-metrics

# Prometheus 타깃 (port-forward 후)
kubectl -n fds port-forward svc/prometheus 9090:9090 &
curl -s localhost:9090/api/v1/targets | grep -o '"job":"[^"]*","[^}]*"health":"[^"]*"'
#   기대: transaction-api up / fds-engine up / kube-state-metrics up / kubelet up / kubelet-cadvisor up
#         node-exporter down  ← k3s hairpin known-issue (정상)

# 룰 로드 확인
curl -s localhost:9090/api/v1/rules | grep -o '"name":"[^"]*"'
#   기대: NodeExporterDown, TargetDown, FDSDetectionBurst, FDSDetectionBurstAnyRule, UnexpectedPodInFdsNs

# Grafana
kubectl -n fds port-forward svc/grafana 3000:3000 &
#   http://localhost:3000  (admin / admin) → Dashboards → FDS 폴더에 3개
```

| 확인 | 기대 | 결과 |
|---|---|---|
| grafana-data PVC Bound | Bound | `NOT RUN` |
| Prometheus 타깃 kubelet = up | up | `NOT RUN` |
| Prometheus 룰 5종 로드 | 로드됨 | `NOT RUN` |
| Grafana FDS 폴더 대시보드 3개 | 3개 provisioned | `NOT RUN` |
| Alertmanager UI 접속 | 접속됨 | `NOT RUN` |

---

## 2. S7 — 이상거래 급증 시연

```bash
# 관측 로그 먼저 시작 (별도 터미널)
kubectl -n fds port-forward svc/prometheus 9090:9090 &
kubectl -n fds port-forward svc/alertmanager 9093:9093 &
./scripts/demo/watch_alerts.sh | tee "docs/evidence/_local/s7_alert_timeline_$(date +%Y%m%dT%H%M%S).log"

# 부하 발생 (edge01 nginx 경유). 45초.
BASE_URL=http://10.1.93.50 ./scripts/demo/s7_transaction_burst.sh
#   대안 진입점:  BASE_URL=http://<worker-node-ip>:30080 ./scripts/demo/s7_transaction_burst.sh
```

관측/캡처:

1. **Prometheus** `sum(increase(fds_detected_total{rule_id="R02"}[5m]))` 가 20 초과 →
   `FDSDetectionBurst` `pending` → `firing`
2. **Alertmanager UI** (`:9093`) — `FDSDetectionBurst` Firing, group `alertname=FDSDetectionBurst / severity=warning`
3. **Grafana** `Application & FDS` — R02 라인이 빨강 임계선(20) 초과, 거래 저장 성공 rate 유지
4. 부하 종료 5~6분 뒤 `increase` 가 20 아래로 → **Resolved**
5. **DB** `psql -h 10.1.93.55 -U fds_app -d fdsdb -c "select transaction_id, amount, fds_detected, fds_rules from transactions where account_id='acc_s7_demo' order by received_at desc limit 5;"`
   → 거래는 전부 저장, 응답은 201 (차단 없음)

| 확인 | 기대 | 결과 |
|---|---|---|
| POST /api/v1/transactions 응답 | 201 (전건) | `NOT RUN` |
| fds_detected_total{rule_id="R02"} 급증 | 증가 | `NOT RUN` |
| FDSDetectionBurst Firing → Resolved | 관측됨 | `NOT RUN` |
| Grafana 임계선 초과 캡처 | 캡처됨 | `NOT RUN` |
| transactions 테이블 저장 확인 | 저장됨 | `NOT RUN` |
| FDSDetectionBurst threshold 20 적정성 | 관측 후 팀 확정 | `NOT VERIFIED` |

---

## 3. S8 — 관측 신뢰성 (타깃 다운)

```bash
# port-forward 불필요 — 스크립트가 kubectl exec 로 pod 안에서 Prometheus 를 조회한다.
# Ctrl-C 로 중단해도 trap 이 kube-state-metrics 를 replicas=1 로 복구한다.
DOWN_SEC=120 ./scripts/demo/s8_target_down.sh
```

- `kube-state-metrics` 0 replica → `up{job="kube-state-metrics"}==0` → `TargetDown` `firing` (for 1m)
- Alertmanager UI: `TargetDown` Firing (severity critical)
- 복구(replica 1) 후 최대 ~4분 내 Resolved
- Grafana `Target Health` — `up` 패널이 0으로 떨어졌다 복귀

**실사례 B (재현 불필요, 인용):** CR-P1-ANS-01-01 precheck 가 dns02 `.53` VM 전원 OFF로
6/6 timeout FAIL → 재기동 후 PASS. "Secondary DNS 다운을 사전점검이 잡았다"
([GH-F] `docs/change/CR-P1-ANS-01-01.md` Precheck execution history) — 이건 infra-ansible
쪽 기록이므로 여기서는 **읽어서 인용만**, 직접 실행 아님.

| 확인 | 기대 | 결과 |
|---|---|---|
| ksm scale 0 시 up==0 | 0 | `NOT RUN` |
| TargetDown Firing (for 1m) | 관측됨 | `NOT RUN` |
| ksm scale 1 복구 시 Resolved | 관측됨 | `NOT RUN` |
| node-exporter 는 S8 대상 아님 (NodeExporterDown 별도) | 분리됨 | 설계상 분리 (문서 근거) |

---

## 4. 잔여 위험 / 후속 Gate

- **임시 k3s 기준.** 실 6-Node(P1-K8S-01, Gate 0 / Bootstrap HOLD) 이관 시 전면 재검증:
  kubelet static target → 워커 3대 IP 또는 `kubernetes_sd`, node-exporter는 hairpin 없이 정석,
  egress NetworkPolicy ipBlock 교체.
- **A5 monitor01 Watchdog** IF-06B `BLOCKED` — S9 는 이 Runbook 범위 밖. 경로 해소 후 별도.
- **임계값 전부 `NOT VERIFIED`** — S7/S8 시연에서 정상 rate 관측 → 팀 확정 → 값 커밋.
- **`UnexpectedPodInFdsNs`** 는 파드 라벨/개수 기반 coarse heuristic. NetworkPolicy drop 지표는
  [BL] §11.3 에 없음(P1-MON-02) — 발표에서 한계로 명시.
- **CI `NOT RUN`** (GitHub Free Private) — 보상통제 유지, CI PASS로 표기 금지.
- 시연 캡처(로그)에 거래 페이로드 포함 가능 → 마스킹 후 보관, 원문 저장 금지 ([BL] §6 정신).
- `docs/evidence/_local/` 는 `.gitignore` 대상(로컬 전용). 저장소엔 검토 완료본만 편입.

---

## 5. 제출 (사람이 수행)

1. 브랜치 생성 후 커밋 (예):
   ```bash
   git switch -c feature/p1-mon-s7-s8-observability
   git add kubernetes/monitoring/ scripts/demo/ docs/runbooks/S7-S8_monitoring_demo_runbook.md
   git commit   # 메시지에 "신규 통제 아님 / threshold NOT VERIFIED / CI NOT RUN" 명시
   git push -u origin feature/p1-mon-s7-s8-observability
   ```
2. PR 생성 후 **독립 Reviewer 지정** — 작성자(이재환)와 같은 사람이 될 수 없다.
3. 리뷰 진행·판정·표기는 CLAUDE.md의 GitHub 리뷰 규칙을 따른다 — 이 구현 문서의 범위가 아니다.
