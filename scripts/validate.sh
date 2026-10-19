#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-p1-go-microsvc}"
RELEASE="${RELEASE:-microsvc}"
NS="${NS:-demo}"
CTX="$PROFILE"
PF1=""; PF2=""

say() { echo -e "\n==> $1"; }
die() { echo -e "\n✗ FAIL: $1" >&2; exit 1; }
cleanup() { [[ -n "$PF1" ]] && kill "$PF1" 2>/dev/null; [[ -n "$PF2" ]] && kill "$PF2" 2>/dev/null; }
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

say "All cluster objects"
K get all

say "PASS ✅  all assertions green, cluster left running for manual poking"
say "   kubectl --context $CTX -n $NS port-forward svc/hello-api 18080:8080"
if [[ "${HELM_UNINSTALL:-0}" == "1" ]]; then
  helm uninstall "$RELEASE" -n "$NS"
fi
