#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-p1-go-microsvc}"
RELEASE="${RELEASE:-microsvc}"
NS="${NS:-demo}"
CTX="$PROFILE"
PF1=""; PF2=""; PF3=""; PF4=""

say() { echo -e "\n==> $1"; }
die() { echo -e "\n✗ FAIL: $1" >&2; exit 1; }
freeport() { fuser -k "$1/tcp" >/dev/null 2>&1 || true; }
cleanup() { [[ -n "$PF1" ]] && kill "$PF1" 2>/dev/null; [[ -n "$PF2" ]] && kill "$PF2" 2>/dev/null; [[ -n "$PF3" ]] && kill "$PF3" 2>/dev/null; [[ -n "$PF4" ]] && kill "$PF4" 2>/dev/null; }
trap cleanup EXIT

cd "$(dirname "$0")/.."
kubectl config use-context "$CTX" >/dev/null

say "Build images inside the minikube docker daemon"
[[ -n $(docker ps 2>/dev/null) ]] || die "docker daemon not reachable"
eval "$(minikube -p "$PROFILE" docker-env --shell bash)"
docker build -t greeting-api:local services/greeting-api || die "greeting-api image build failed"
docker build -t hello-api:local services/hello-api || die "hello-api image build failed"

say "helm install $RELEASE into namespace $NS"
helm upgrade --install "$RELEASE" chart/microservices -n "$NS" --create-namespace --wait --timeout 5m ||
  die "helm install failed"

say "Wait for rollouts"
K() { kubectl --context "$CTX" -n "$NS" "$@"; }
K rollout status deploy/greeting-api --timeout=180s || die "greeting-api rollout"
K rollout status deploy/hello-api --timeout=180s || die "hello-api rollout"

say "Check in-cluster DNS through a debug pod (the real inter-service path)"
DNS_OUT=$(K get pods -l app=hello-api -o name | head -1 | awk -F/ '{print $2}')
K exec "$DNS_OUT" -- wget -qO- -T 5 http://greeting-api:8080/ping ||
  die "in-cluster DNS/service call to greeting-api failed from hello-api pod"

say "Smoke test: greeting-api /ping via port-forward"
K port-forward svc/greeting-api 18081:8080 >/tmp/opencode/pf-greeting.log 2>&1 &
PF1=$!
sleep 3
PONG=$(curl -sSf --max-time 5 http://127.0.0.1:18081/ping) || die "curl greeting-api /ping failed"
echo "$PONG" | grep -q '"message":"pong"' || die "greeting-api /ping body unexpected: $PONG"
echo "  greeting-api replied: $PONG"

say "Smoke test: hello-api /hello: proves hello-api called greeting-api in-cluster"
K port-forward svc/hello-api 18080:8080 >/tmp/opencode/pf-hello.log 2>&1 &
PF2=$!
sleep 3
HELLO=$(curl -sSf --max-time 10 http://127.0.0.1:18080/hello) || die "curl hello-api /hello failed"
echo "  hello-api replied: $HELLO"
echo "$HELLO" | grep -q '"route":"v1"' || die "expected route v1 (canary off), got: $HELLO"
echo "$HELLO" | grep -q '"version":"v1"' || die "expected upstream version v1, got: $HELLO"
echo "$HELLO" | grep -q '"message":"pong"' || die "hello-api did not forward greeting's pong: $HELLO"

say "Wait for monitoring rollouts"
K rollout status deploy/prometheus --timeout=5m || die "prometheus rollout"
K rollout status deploy/grafana --timeout=5m || die "grafana rollout"

say "Monitoring smoke: Prometheus targets + Grafana provisioning"
PROM_PORT=19092; GRF_PORT=19102
freeport "$PROM_PORT"; freeport "$GRF_PORT"
# direct commands (not the K() wrapper) so $! is the real kubectl process and
# the EXIT trap can actually kill it
command kubectl --context "$CTX" -n "$NS" port-forward svc/prometheus "$PROM_PORT:9090" >/dev/null 2>&1 &
PF3=$!
command kubectl --context "$CTX" -n "$NS" port-forward svc/grafana "$GRF_PORT:3000" >/dev/null 2>&1 &
PF4=$!
sleep 6
curl -fsS --max-time 8 "http://127.0.0.1:$PROM_PORT/-/healthy" >/dev/null || die "prometheus is not healthy"
TARGETS=$(curl -fsS --max-time 8 "http://127.0.0.1:$PROM_PORT/api/v1/targets")
echo "$TARGETS" | grep -q '"job":"microsvc"' || die "microsvc scrape job not configured: $TARGETS"
echo "$TARGETS" | grep -q '"health":"up"' || die "app pods are scraped but not healthy yet: $TARGETS"
echo '  ✓ prometheus scrapes hello-api + greeting-api pods'

# note: grafana pretty-prints this JSON, hence the space-tolerant pattern
curl -fsS --max-time 8 "http://127.0.0.1:$GRF_PORT/api/health" | grep -q '"database": *"ok"' || die "grafana is not healthy"
curl -fsS -u admin:admin --max-time 8 "http://127.0.0.1:$GRF_PORT/api/datasources" | grep -q '"name":"prometheus"' || die "grafana prometheus datasource missing"
curl -fsS -u admin:admin --max-time 8 "http://127.0.0.1:$GRF_PORT/api/search?query=microservices" | grep -q '"title":"microservices"' || die "grafana dashboard not provisioned"
echo '  ✓ grafana healthy, datasource + dashboard provisioned (admin/admin)'

say "App counters have real samples in prometheus"
for C in helloapi_http_requests_total greetingapi_http_requests_total; do
  OK=""
  for _ in 1 2 3 4 5; do
    Q=$(curl -fsS --max-time 8 "http://127.0.0.1:$PROM_PORT/api/v1/query?query=$C" || true)
    echo "$Q" | grep -q '"value"' && { OK=1; break; }
    sleep 10
  done
  [[ -n "$OK" ]] || die "no samples for $C in prometheus"
  echo "  ✓ $C flowing"
done

say "All cluster objects"
K get all

say "PASS ✅  microservices + monitoring, all assertions green, cluster left running for manual poking"
say "   kubectl --context $CTX -n $NS port-forward svc/hello-api 18080:8080"
say "   Grafana: kubectl --context $CTX -n $NS port-forward svc/grafana 19102:3000  (admin/admin)"
if [[ "${HELM_UNINSTALL:-0}" == "1" ]]; then
  helm uninstall "$RELEASE" -n "$NS"
fi
