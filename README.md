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
Two different directions of traffic need two different addressing schemes:

- **Tickets (inside Minikube) → LocalStack S3 (on the host):** uses
  `http://host.minikube.internal:4566` (Minikube's built-in DNS name for reaching the host
  machine from inside a pod). Configured via the `S3_ENDPOINT` env var in
  `k8s/tickets-deployment.yaml`.
- **Lambda (inside the LocalStack container, on the host's Docker) → Notifications (inside
  Minikube):** `host.minikube.internal` does **not** resolve in this direction. Instead,
  `localstack/deploy-lambda.sh` configures the Lambda's `NOTIFICATIONS_URL` to
  `http://<minikube ip>:30080`, hitting the `notifications-external` NodePort Service
  (`k8s/notifications-external-service.yaml`) added specifically for this purpose. The
  original `notifications` ClusterIP Service and the Ingress routing are untouched.

This is the one supported local setup for Task 1. If your Minikube driver changes the host
machine's reachability (e.g., some VM-based drivers), re-run `minikube ip` and pass it
explicitly: `./localstack/deploy-lambda.sh http://<ip>:30080`.

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
  git history until that history is rewritten (e.g. `git filter-repo`) and force-pushed.
  Because that old private key must be treated as compromised, generate a **fresh** key pair
  (step 2 above) rather than reusing the one from history, and rotate to it via the Secret in
  step 3. Full key-rotation *tooling* (dual-key verification, zero-downtime rotation) is
  Task 4 — for Task 1, this is a one-time manual replacement.

## What's intentionally out of scope for Task 1

Per the phased implementation plan: no database, no message broker (Kafka/RabbitMQ), no
Terraform, no Helm, no Argo CD, no Prometheus/Loki/Grafana, no JWT key rotation, no
multi-cloud namespaces. These are later tasks.
