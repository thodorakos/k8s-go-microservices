# k8s-go-microservices

Two tiny Go microservices on Kubernetes, deployed with one Helm chart. It covers
the "hello world of microservices" a junior engineer needs:

- 2 services built as containers (multi-stage Docker builds, Go stdlib only)
- `hello-api` → `greeting-api` communication **over in-cluster Service DNS** (`http://greeting-api:8080`)
- Deployments, Services, readiness/liveness probes via a single **Helm** umbrella chart
- A repeatable validation script with real assertions (exit code 0 = everything works)

## Architecture

```
 you ──curl──▶ |hello-api| ──http://greeting-api:8080/ping──▶ |greeting-api|
                Service(DNS)  Kubernetes ClusterIP/ServiceNames   Service(DNS)
```

## Tech

- **Go**: stdlib `net/http` only, zero dependencies
- **Helm 4.x**: one chart manages both Deployments + Services
- **minikube (docker driver)** as the test cluster

## Layout

```
services/          the two services; each: main.go + go.mod + Dockerfile
chart/microservices/  the Helm chart that deploys both
scripts/validate.sh   builds images, installs chart, asserts the service-to-service call
```

## How the chart works

`values.yaml` drives everything:

```yaml
services:
  greeting-api: { enabled, image, tag, port, replicas, env }
  hello-api:    { ..., GREETING_API_URL: http://greeting-api:8080 }
features:
  canary: { enabled: false, weight: 50 }
```

`templates/deployment.yaml` + `templates/service.yaml` `range` over `services`,
so adding a third service is a values change, not new YAML files.

## Canary enrichment (optional)

Turn the feature flag on with `--set features.canary.enabled=true` and the chart also deploys
`greeting-api-v2` (same image, `SERVICE_VERSION=v2`, its own Service). `hello-api` then sends a
percentage (`weight`) of its calls to v2 and reports `route: v2` / `version: v2` in the response.
It shows how version-splitting can be done at the application level, without a
service mesh.

## Run it

Requirements: docker, minikube, kubectl, helm.

```bash
./scripts/validate.sh            # starts nothing itself; profiles the cluster p1-go-microsvc
```

The script expects a running minikube profile (default name `p1-go-microsvc`):

```bash
minikube start -p p1-go-microsvc --driver=docker --cpus=2 --memory=1950 --container-runtime=docker \
  --apiserver-ips=192.168.49.2 --apiserver-name=192.168.49.2
```

(`--apiserver-ips/--apiserver-name` are a documented WSL2 workaround for uppercase hostnames
breaking kubeadm cert SANs, minikube issue #9175.)

## Manual exploration after validation

```bash
kubectl --context p1-go-microsvc -n demo get all
kubectl --context p1-go-microsvc -n demo port-forward svc/hello-api 18080:8080
curl http://127.0.0.1:18080/hello

helm get values -n demo microsvc
helm delete -n demo microsvc
```

## Teardown

```bash
helm uninstall microsvc -n demo; minikube delete -p p1-go-microsvc
```

## Validation results

Captured on minikube v1.39.0, Kubernetes v1.37.0, docker driver, 2 CPUs / 1950MB (WSL2 laptop).

```console
$ ./scripts/validate.sh
==> Build images inside the minikube docker daemon
#12 naming to docker.io/library/greeting-api:local done
#12 naming to docker.io/library/hello-api:local    done

==> helm install microsvc into namespace demo
NAME: microsvc
NAMESPACE: demo
STATUS:     deployed  (revision: 2)

==> Wait for rollouts
deployment "greeting-api" successfully rolled out
deployment "hello-api" successfully rolled out

==> Check in-cluster DNS through a debug pod (the real inter-service path)
{"service":"greeting-api","message":"pong","version":"v1","host":"greeting-api-79b67db45b-stfht"}

==> Smoke test: greeting-api /ping via port-forward
  greeting-api replied: {"service":"greeting-api","message":"pong","version":"v1",
                         "host":"greeting-api-79b67db45b-stfht"}

==> Smoke test: hello-api /hello: proves hello-api called greeting-api in-cluster
  hello-api replied: {"service":"hello-api","route":"v1","message":"pong","version":"v1",
                      "upstream_host":"greeting-api-79b67db45b-stfht"}

==> All cluster objects
NAME                                READY   STATUS    RESTARTS   AGE
pod/greeting-api-79b67db45b-stfht   1/1     Running   0          7m43s
pod/hello-api-7975868fb-74s5m       1/1     Running   0          7m43s

NAME                   TYPE        CLUSTER-IP      PORT(S)
service/greeting-api   ClusterIP   10.102.116.63   8080/TCP
service/hello-api      ClusterIP   10.102.63.42    8080/TCP

NAME                           READY
deployment.apps/greeting-api   1/1
deployment.apps/hello-api      1/1

==> PASS ✅  all assertions green, cluster left running for manual poking
```

### Canary proof

With `--set features.canary.enabled=true --set features.canary.weight=50` and
`hello-api` reconfigured (env vars only) to split traffic, 20 consecutive
`k -n demo port-forward svc/hello-api 18080:8080` + `curl` calls:

```console
== 20 calls, canary weight 50 ==
     10 "route":"v1"
     10 "route":"v2"

== sample v2 response ==
{"service":"hello-api","route":"v2","message":"pong","version":"v2",
 "upstream_host":"greeting-api-v2-56646f6874-9pdx6"}
```

`greeting-api-v2` gets deployed by the same chart (only a `--set` away) and its
own Service; `hello-api` picks it via the `CANARY_WEIGHT` / `GREETING_API_V2_URL`
env vars and labels the hop with `route: v2`.

