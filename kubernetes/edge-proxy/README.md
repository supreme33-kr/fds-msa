# edge01 nginx reverse proxy — D18 Option A

> Client → edge01:80 (nginx) → transaction-api NodePort:30080 → Pod:8000
> 08-28 edge01(k3s 단일 노드 테스트 환경)에서 전체 체인 실증 완료.
> 실제 3-Worker 클러스터 확보 시 upstream에 Worker 3대 IP만 추가하면 그대로 재사용 가능.

## 설치

```bash
sudo dnf install -y nginx
sudo cp fds.conf /etc/nginx/conf.d/fds.conf
sudo nginx -t
sudo systemctl enable --now nginx
```

## SELinux / firewalld

```bash
sudo setsebool -P httpd_can_network_connect 1
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload
```

## ⚠️ k3s 테스트 환경 전용 주의사항 (실제 클러스터에서는 해당 없음)

edge01 자체를 k3s 노드로 겸용할 경우, k3s 기본 탑재 Traefik이 `LoadBalancer` Service로
80/443 포트를 자동 선점하여 nginx와 충돌한다. 08-28 실증 중 실제로 발생했던 문제이며,
증상은 nginx가 정상 기동되고 요청도 받지만 응답이 Go 스타일 404(`"404 page not found"`,
`Content-Type: text/plain`)로 나오는 형태였다.

**edge01이 k3s 노드를 겸하는 임시 테스트 환경에서만 필요한 조치:**

```bash
kubectl delete svc traefik -n kube-system
```

**실제 운영 토폴로지(edge01이 클러스터 외부 별도 VM)에서는 이 문제가 발생하지 않으므로
이 조치도 불필요하다.**

## 검증

```bash
curl -s http://<edge01-IP>:80/health
# {"status":"ok"} 기대
```
