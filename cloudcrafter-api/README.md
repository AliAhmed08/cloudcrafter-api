# CloudCrafter API — Capstone

Four independent Express microservices (Users, Events, Tickets, Notifications) deployed to
Kubernetes, fronted by an Nginx Ingress, with an event-driven ticket-receipt notification
flow powered by LocalStack (S3 + Lambda).

This README currently covers **Task 1** only: Kubernetes deployment + the S3 → Lambda →
Notifications event flow. Later tasks (Helm, CI/CD, Argo CD, observability, JWT rotation,
multi-cloud) will extend this document as they're implemented.

## Prerequisites

- Docker
- kubectl
- Minikube
- Node.js (v18+) and npm
- `zip` (for packaging the Lambda) — most Linux/macOS systems have this; on Windows use WSL2
  or Git Bash with zip installed
- `awslocal` (`pip install awscli-local`) — convenience wrapper around the AWS CLI pointed at
  LocalStack. Plain `aws --endpoint-url=http://localhost:4566 ...` also works.

## 1. Start Minikube

```bash
minikube start
minikube addons enable ingress
```

Wait for the ingress controller pod to be Running:

```bash
kubectl get pods -n ingress-nginx --watch
```

## 2. Generate a local JWT key pair (development only)

The repository no longer ships committed JWT keys (see "JWT key security" below). Generate
your own RS256 pair for local use — these files are gitignored and never committed:

```bash
mkdir -p services/users/keys
openssl genrsa -out services/users/keys/private.key 2048
openssl rsa -in services/users/keys/private.key -pubout -out services/users/keys/public.key
```

## 3. Create the Kubernetes Secret for JWT keys

```bash
kubectl create secret generic users-jwt-keys \
  --from-file=private.key=services/users/keys/private.key \
  --from-file=public.key=services/users/keys/public.key
```

This is the **only** place the key material goes — never into a committed YAML file, never
into logs, never into this README.

## 4. Build the service images inside Minikube

```bash
eval $(minikube -p minikube docker-env)   # Linux/macOS
# On Windows PowerShell:  & minikube -p minikube docker-env | Invoke-Expression

docker build -t users:1.0 services/users
docker build -t events:1.0 services/events
docker build -t tickets:1.0 services/tickets
docker build -t notifications:1.0 services/notifications
```

(Equivalently, you can use `minikube image build -t users:1.0 services/users`, etc., which
avoids the docker-env step.)

## 5. Deploy to Kubernetes

```bash
kubectl apply -f k8s/
kubectl get pods --watch
```

Wait until all four Deployments show `1/1 Running` with `READY 1/1` (liveness/readiness
probes must pass).

## 6. Point cloudcrafter.local at Minikube

```bash
echo "$(minikube ip) cloudcrafter.local" | sudo tee -a /etc/hosts
```

On Windows, add the equivalent line to `C:\Windows\System32\drivers\etc\hosts` (as
Administrator): `<minikube ip> cloudcrafter.local`.

Verify:

```bash
curl http://cloudcrafter.local/api/users/health
curl http://cloudcrafter.local/api/events/health
curl http://cloudcrafter.local/api/tickets/health
curl http://cloudcrafter.local/api/notifications/health
```

## 7. Start LocalStack

```bash
cd localstack
docker compose up -d
docker compose logs -f localstack   # wait for "Ready." and the init script's bucket-created message
```

The `cloudcrafter-ticket-receipts` bucket is created automatically by
`localstack/init/01-create-bucket.sh` on startup.

## 8. Deploy the Lambda and wire the S3 event trigger

From the repo root:

```bash
./localstack/deploy-lambda.sh
```

This script auto-detects `minikube ip` and configures the Lambda's `NOTIFICATIONS_URL`
environment variable to reach the `notifications-external` NodePort Service (see
"Networking" below). It also wires an `s3:ObjectCreated:*` event notification on the bucket
so the Lambda fires automatically — no manual `aws lambda invoke` needed.

## 9. Test ticket creation (triggers the whole event chain)

```bash
curl -X POST http://cloudcrafter.local/api/tickets/tickets \
  -H "Content-Type: application/json" \
  -d '{"eventId": 1, "userId": 1}'
```

**Reliability note:** when `S3_ENDPOINT` is configured (the default in-cluster setup — see
`k8s/tickets-deployment.yaml`), a successful S3 upload is *required* for ticket creation to
succeed. If LocalStack is unreachable or the upload otherwise fails, this call returns `502`
and no ticket is created — by design, so "ticket created" always means "the event chain was
triggered," which is what the capstone demonstration needs to be deterministic. (Running
Tickets without `S3_ENDPOINT` set at all — e.g. quick local API testing without LocalStack —
is a separate, explicit opt-out and still returns `201` with `s3.uploaded: false`.)

## 10. Verify the notification was created automatically

```bash
curl http://cloudcrafter.local/api/notifications/notifications
```

You should see a notification whose message references the `receiptId` from step 9 —
generated entirely by the S3 → Lambda → Notifications chain, with no manual call to
`POST /notify`.

## Automated verification

```bash
BASE_URL=http://cloudcrafter.local ./test/verify-task1.sh
```

This script checks all ten Definition-of-Done items end-to-end (pod status, Service
existence, Ingress routing, health checks, login, ticket creation, S3 upload, and the
automatic notification), and exits non-zero if anything fails.

## Networking: LocalStack ↔ Kubernetes

LocalStack runs as a plain Docker container (via `docker compose`), **outside** Minikube.
Two different directions of traffic need two different addressing schemes, and neither
should ever rely on plain `localhost` — `localhost` inside a pod means the pod, `localhost`
inside the LocalStack container means the LocalStack container, and `localhost` on the
Windows host means the Windows host. None of those three are the same machine.

**Driver assumption:** this setup is verified against Minikube's `docker` driver, which is
the default when running `minikube start` on Windows with Docker Desktop's WSL2 backend
(check with `minikube profile list`, or look for `"Driver": "docker"` in
`minikube profile list -o json`). If you're on a different driver (`hyperv`, `virtualbox`),
use the fallback at the bottom of this section instead of the NodePort approach — the
addresses below are not guaranteed to be reachable from a sibling Docker container on those
drivers.

### Direction 1: Tickets pod (inside Minikube) → LocalStack S3 (on the host)

Uses `http://host.minikube.internal:4566` — Minikube's built-in DNS name for reaching the
host machine from inside a pod. This is set via the `S3_ENDPOINT` env var in
`k8s/tickets-deployment.yaml`. On the `docker` driver over Docker Desktop, this resolves
correctly for Windows and macOS (Docker Desktop provides the underlying `host.docker.internal`
mapping that Minikube's `host.minikube.internal` is built on). It is **not** guaranteed on
plain Linux with the `docker` driver and no Docker Desktop — not relevant for a Windows +
WSL2 + Docker Desktop setup, but worth knowing if you ever move this to a Linux CI runner.

**Verify this direction directly**, before trusting it through the app:

```bash
kubectl run netcheck --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sf http://host.minikube.internal:4566/_localstack/health
```

If that hangs or fails, LocalStack's port 4566 either isn't published (check
`docker compose ps` in `localstack/`) or Docker Desktop's WSL2 integration isn't enabled for
the distro you ran `minikube start` from (check Docker Desktop → Settings → Resources → WSL
Integration).

### Direction 2: LocalStack Lambda (on the host's Docker) → Notifications (inside Minikube)

`host.minikube.internal` does **not** resolve in this direction — it only helps pods reach
the host, not the reverse. Instead, `localstack/deploy-lambda.sh` configures the Lambda's
`NOTIFICATIONS_URL` to `http://<minikube ip>:30080`, hitting the `notifications-external`
NodePort Service (`k8s/notifications-external-service.yaml`) added specifically for this
purpose. The original `notifications` ClusterIP Service and the Ingress routing are
untouched. `deploy-lambda.sh` now runs a **preflight check** — it `curl`s
`http://<minikube ip>:30080/health` itself before wiring anything, and fails loudly with a
troubleshooting checklist if that doesn't respond, rather than silently deploying a Lambda
that will never succeed.

**Verify this direction directly, from the same shell you'll run `docker compose` /
`deploy-lambda.sh` from** (this matters — see the WSL2 note below):

```bash
curl -sf http://$(minikube ip):30080/health
```

**WSL2-specific requirement:** run `minikube start`, `docker compose up`, and
`deploy-lambda.sh` all from the **same WSL2 distro/terminal**. If you start Minikube from
WSL2 but then run `docker compose` from Windows PowerShell (or a different WSL2 distro), you
may be talking to a different Docker context, and `minikube ip` reachability is not
guaranteed across that boundary. Docker Desktop's WSL2 backend generally shares one Docker
engine across integrated distros, but mixing shells is the single most common source of
"it worked from one terminal and not the other" on this stack — keep everything in one shell.

### Fallback: if NodePort reachability fails (VPN, firewall, non-docker driver)

If the Direction 2 preflight check fails and isn't a quick fix (corporate VPN routing,
`hyperv` driver, etc.), use `kubectl port-forward` plus Docker Desktop's `host.docker.internal`
instead of `minikube ip` + NodePort — this path only depends on Docker Desktop's host
bridging, not on Minikube's driver-specific networking:

```bash
# In a dedicated terminal, left running for the duration of your testing:
kubectl port-forward svc/notifications 3000:3000
```

```bash
# Then point the Lambda at the host via Docker Desktop's host.docker.internal,
# which every container on Docker Desktop can resolve regardless of Minikube driver:
./localstack/deploy-lambda.sh http://host.docker.internal:3000
```

This is more moving parts (an extra terminal to keep open) so it's the fallback, not the
default — but it's the most portable option if the primary path doesn't work in your specific
Windows/WSL2/Docker Desktop configuration.

## JWT key security

- `services/users/private.key` and `services/users/public.key` are **no longer tracked in
  git** and are no longer copied into the Docker image (`services/users/.dockerignore`
  excludes `keys/`, `*.key`, `*.pem`).
- In Kubernetes, the Users service reads keys from `/etc/cloudcrafter/jwt`, mounted from the
  `users-jwt-keys` Secret (see step 3 above and `k8s/users-deployment.yaml`).
- For local (non-container) development, set `JWT_KEYS_DIR` to point at a directory
  containing your own `private.key`/`public.key`, or place them at
  `services/users/keys/` (the default, and gitignored).
- **Important history note:** the original key pair was committed in the initial commit of
  this repository. Removing the files from tracking (`git rm --cached`) stops them from
  being copied into future clones' *working tree*, but the old key material still exists in
  git history until that history is rewritten and force-pushed. See
  [`docs/jwt-key-history-cleanup.md`](docs/jwt-key-history-cleanup.md) for the exact,
  safe procedure (using `git filter-repo`, in a disposable clone). Because that old private
  key must be treated as compromised regardless of the history rewrite, generate a **fresh**
  key pair (step 2 above) rather than reusing the one from history, and load it via the
  Secret in step 3. Full key-rotation *tooling* (dual-key verification, zero-downtime
  rotation) is Task 4 — for Task 1, this is a one-time manual replacement.

## What's intentionally out of scope for Task 1

Per the phased implementation plan: no database, no message broker (Kafka/RabbitMQ), no
Terraform, no Helm, no Argo CD, no Prometheus/Loki/Grafana, no JWT key rotation, no
multi-cloud namespaces. These are later tasks.
