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
openssl genrsa -out services/users/keys/current-private.key 2048
openssl rsa -in services/users/keys/current-private.key -pubout -out services/users/keys/current-public.key
echo -n "key-initial" > services/users/keys/current-kid
```

## 3. Create the Kubernetes Secret for JWT keys

```bash
kubectl create secret generic users-jwt-keys \
  --from-file=current-private.key=services/users/keys/current-private.key \
  --from-file=current-public.key=services/users/keys/current-public.key \
  --from-file=current-kid=services/users/keys/current-kid
```

This is the **only** place the key material goes — never into a committed YAML file, never
into logs, never into this README. See `docs/jwt-key-rotation.md` for how to rotate this key
later without downtime.

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

# Helm Deployment

Task 2A packages the Task 1 deployment as a Helm chart under `charts/cloudcrafter/`. This
does not replace the raw manifests in `k8s/` — see "Relationship between `k8s/` and
`charts/cloudcrafter/`" below.

**Prerequisites:** everything from Task 1 (Minikube running, service images built and loaded
into Minikube — see steps 1 and 4 above) plus Helm 3 installed locally.

## 1. Create the JWT Secret (same as Task 1 — the chart never creates this for you)

The chart deliberately does not template a Secret containing real key material — it only
references one that must already exist:

```bash
mkdir -p services/users/keys
openssl genrsa -out services/users/keys/current-private.key 2048
openssl rsa -in services/users/keys/current-private.key -pubout -out services/users/keys/current-public.key
echo -n "key-initial" > services/users/keys/current-kid

kubectl create secret generic users-jwt-keys \
  --from-file=current-private.key=services/users/keys/current-private.key \
  --from-file=current-public.key=services/users/keys/current-public.key \
  --from-file=current-kid=services/users/keys/current-kid
```

If you already created this Secret while following the Task 1 instructions above and it's
still present in your cluster (`kubectl get secret users-jwt-keys`), you can skip this step.

## 2. Check the chart (basic sanity check, no cluster needed)

```bash
helm show chart ./charts/cloudcrafter
helm show values ./charts/cloudcrafter
```

## 3. Lint the chart

```bash
helm lint ./charts/cloudcrafter
```

## 4. Render templates (dry, no cluster needed)

```bash
helm template cloudcrafter ./charts/cloudcrafter
```

Inspect the output and confirm: all four Deployments render, all Services render (including
`notifications-external`), the Ingress renders with all four `/api/*` paths, every Deployment
has `livenessProbe`/`readinessProbe` and `resources`, the Users Deployment references the
`users-jwt-keys` Secret (not literal key content), and the Tickets Deployment references the
`tickets-s3-credentials` Secret for its S3 env vars.

## 5. Install the chart

If Minikube's Ingress needs `minikube tunnel` running (Windows + `docker` driver — see
"Networking" above), make sure that's already running in its own terminal, and that
`cloudcrafter.local` resolves to `127.0.0.1` in your hosts file, before installing:

```bash
helm install cloudcrafter ./charts/cloudcrafter
```

To install into a different namespace (this chart has no hardcoded namespace, so this just
works):

```bash
helm install cloudcrafter ./charts/cloudcrafter --namespace cloudcrafter --create-namespace
```

Optionally, dry-run first:

```bash
helm install cloudcrafter ./charts/cloudcrafter --dry-run --debug
```

## 6. Check the release

```bash
helm list
helm status cloudcrafter
kubectl get pods -l app.kubernetes.io/part-of=cloudcrafter
kubectl get svc -l app.kubernetes.io/part-of=cloudcrafter
kubectl get ingress
```

Then verify the same way as Task 1:

```bash
curl http://cloudcrafter.local/api/users/health
curl http://cloudcrafter.local/api/events/health
curl http://cloudcrafter.local/api/tickets/health
curl http://cloudcrafter.local/api/notifications/health
```

## 7. Uninstall the release

```bash
helm uninstall cloudcrafter
```

This removes everything the chart created (Deployments, Services, Ingress, the
`tickets-s3-credentials` Secret). It does **not** remove the `users-jwt-keys` Secret, since
the chart never created that Secret in the first place — delete it separately if you want it
gone: `kubectl delete secret users-jwt-keys`.

## Configuring the chart

Everything in `charts/cloudcrafter/values.yaml` is overridable via `-f` or `--set`, for
example, to point at a different image registry without touching any template:

```bash
helm install cloudcrafter ./charts/cloudcrafter \
  --set services.users.image.repository=ghcr.io/aliahmed08/cloudcrafter-users \
  --set services.users.image.tag=1.1.0
```

Never put real secrets (real AWS credentials, real JWT keys) into a committed values file —
see the comments directly in `values.yaml`'s `s3:` and `jwt:` sections for exactly which
values are safe defaults (LocalStack's public dummy credentials) versus which must always
come from a Secret you create out-of-band.

## Helm versioning

`charts/cloudcrafter/Chart.yaml` currently pins `version: 0.1.0` (the chart's own
template/structure version) and `appVersion: "1.0.0"` (the application version, driven by the
image tags in `values.yaml`). For now, both are bumped manually and only when something
actually changes — not on every edit. Once CI/CD is implemented (a later Task 2 step), the
plan is for the pipeline to bump `Chart.yaml`'s `version` automatically on merges that touch
`charts/cloudcrafter/`, and to set `appVersion` (and the default image tags) to match the
semantically-versioned image tag being published — so a Helm chart version becomes a
reliable pointer to an exact, reproducible set of image tags. That automation is out of scope
for this step.

## Relationship between `k8s/` and `charts/cloudcrafter/`

- **`k8s/`** — the Task 1 raw Kubernetes manifest baseline. Kept as-is, deployable directly
  with `kubectl apply -f k8s/`. This is the reference implementation the Helm chart is
  templated from, and stays useful for quickly diffing "what does the chart actually render"
  against "what did Task 1 originally specify."
- **`charts/cloudcrafter/`** — the packaged, reusable, versioned deployment mechanism.
  Prefer this going forward: it's what future Task 2 steps (CI/CD image tag injection, Argo
  CD, multi-environment `aws`/`google-cloud` namespaces) will build on top of.

# Task 2 — Packaging, CI/CD, GitOps & Portability

This section covers everything added on top of Task 1 and the Task 2A Helm chart: automated
testing/CI, GHCR image publishing, Argo CD GitOps, and simulated multi-cloud portability
(`aws` / `google-cloud` namespaces, same chart, no cloud-specific hardcoding).

## 1. Repository structure (new in this step)

```
.github/workflows/
  ci.yml                    # tests + Dockerfile + Helm validation, on every PR/push to main
  release.yml                # builds & publishes all 4 images to GHCR
argocd/
  application-aws.yaml       # Argo CD Application -> aws namespace
  application-google-cloud.yaml  # Argo CD Application -> google-cloud namespace
k8s/namespaces/
  aws.yaml                   # plain Namespace manifest
  google-cloud.yaml          # plain Namespace manifest
charts/cloudcrafter/
  values-aws.yaml             # minimal env overlay (NOT a full values.yaml copy)
  values-google-cloud.yaml    # minimal env overlay
  values-ghcr.example.yaml    # example of switching to GHCR-mode images
services/*/test/*.test.js     # per-service test suites (see "Testing" below)
```

Everything from Task 1 (`k8s/`, `localstack/`) and Task 2A (`charts/cloudcrafter/` core
templates) is unchanged in structure — this step only adds files, plus two small, necessary
edits: a testability seam in each `server.js` (exporting `app`, guarding `app.listen()` behind
`require.main === module` — no request-handling logic changed), and the chart's
`imageRegistry`/`imageTag` override mechanism (see "GHCR + Helm integration" below).

## 2. Testing

Each service now has a real test suite under `services/<name>/test/`, using **only Node's
built-in `node:test` and `node:assert` modules plus the native `fetch`** (stable since Node
18) — no test framework dependency was added. Run any service's tests locally:

```bash
cd services/users && npm install && npm test
```

Coverage: Users (health, valid/invalid login, protected route with valid/missing/invalid
JWT — using a throwaway RSA key pair generated in-memory per test run, never committed),
Events (health, list/get/create, 404 and 400 cases), Tickets (health, ticket creation tested
via the S3-not-configured opt-out path — no AWS credentials needed in CI — plus the 400 case),
Notifications (health, `/notify` creating a visible notification, 400 case). All 20 tests
across the four services were run and pass.

## 3. GitHub Actions CI (`.github/workflows/ci.yml`)

Runs on every pull request and every push to `main`. Three job groups:

- **`test-services`** — matrix over the 4 services × Node 18.x/20.x: `npm install`
  (no lockfile is committed, so this uses `install` not `ci`), `node --check server.js`,
  `npm test`.
- **`docker-build-validate`** — matrix over the 4 services: `docker build` each Dockerfile
  (validation only, nothing is pushed here — see release.yml for publishing).
- **`helm-validate`** — `helm lint`, `helm template` with default values, `helm template`
  with each of the `values-aws.yaml`/`values-google-cloud.yaml` overlays, and a static grep
  guard that fails the build if any chart *template* contains a hardcoded `namespace: aws` or
  `namespace: google-cloud` line.
- **`ci-summary`** — depends on all of the above; gives branch protection one single check
  name to require instead of enumerating every matrix leg (see "Branch protection" below).

This workflow needs **no cloud credentials, no registry login, and never runs `kubectl` or
`helm install` against a real cluster** — it only validates.

## 4. GHCR image publishing (`.github/workflows/release.yml`)

Builds and pushes all four images — `ghcr.io/<owner>/cloudcrafter-users`,
`cloudcrafter-events`, `cloudcrafter-tickets`, `cloudcrafter-notifications` — using
**only the built-in `GITHUB_TOKEN`** (via `docker/login-action`, no PAT or registry secret
needs to be created). The owner is derived from `github.repository_owner` (lowercased, since
GHCR requires lowercase image paths) — your GitHub username is never hardcoded anywhere in
the workflow.

Triggers: push to `main`, push of a version tag (`v*.*.*`), or manual dispatch.

## 5. Image tagging strategy

Every build is tagged with an **immutable** `sha-<short-commit-sha>` tag — this is the tag
that should always be trusted for "exactly this code." On top of that:

- Push to `main` also gets a moving `edge` tag (latest main build — for convenience only,
  never relied on exclusively).
- Pushing a version tag like `v1.2.3` additionally tags the image `1.2.3`, `1.2`, and
  `latest`.

This is deliberately **not** "just `latest`" — per the capstone requirement, at least one
immutable tag (`sha-...`, and `1.2.3` on releases) is always present, so a specific build can
always be pinned exactly, including by `charts/cloudcrafter/values.yaml`'s `imageTag`.

## 6. Semantic versioning — Helm chart vs. application

`charts/cloudcrafter/Chart.yaml`:

```yaml
version: 0.2.0        # the CHART's own version — bumped when templates/values structure changes
appVersion: "1.0.0"   # the APPLICATION's version — tracks what's actually running (image tags)
```

These are independent on purpose: `version` changed (0.1.0 → 0.2.0 in this step) because the
chart gained new templating capability (`imageRegistry`/`imageTag` overrides), even though no
application code changed at all (`appVersion` stayed `1.0.0`). Conversely, a new application
release (new image tag) wouldn't necessarily require any chart template change. Both are
currently bumped **manually**, only when something genuinely changes — full CI-automated
version bumping (e.g. bumping `Chart.yaml` automatically when a PR touching `charts/` merges)
is a documented future enhancement, not implemented here (see the comment in `Chart.yaml`) —
being explicit that this isn't built yet rather than implying it is.

## 7. GHCR + Helm integration — two modes

The chart supports two image-sourcing modes without ever hardcoding a registry owner in a
template:

**Local mode (default — Task 1/2A behavior, completely unchanged):**
```yaml
# values.yaml defaults, per service:
image:
  repository: users   # etc. per service
  tag: "1.0"
```
Works exactly as before with `minikube image load`.

**CI/GHCR mode** — set two top-level values, and every service's image is rewritten
automatically to `<imageRegistry>/cloudcrafter-<service>:<imageTag>`:
```bash
helm install cloudcrafter ./charts/cloudcrafter \
  --set imageRegistry=ghcr.io/aliahmed08 \
  --set imageTag=1.0.0
```
See `charts/cloudcrafter/values-ghcr.example.yaml` for the equivalent `-f` form, and the
commented-out `helm.parameters` block in `argocd/application-aws.yaml` for how Argo CD would
apply the same override once real GHCR images exist.

## 8. Argo CD (GitOps)

Two Application manifests under `argocd/`, both pointing at this same Git repository and the
same chart path:

```
Developer -> GitHub -> GitHub Actions (test, build, push to GHCR)
                            -> Git (chart/values updates)
                                -> Argo CD (watches Git) -> Kubernetes
```

CI **never** deploys directly — it only tests and publishes. Argo CD is the only thing that
ever reconciles a real cluster, by continuously watching this Git repo. Both Applications set:

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
```

`prune: true` removes cluster resources that are no longer in Git; `selfHeal: true` reverts
manual `kubectl edit`-style drift back to what Git says; `CreateNamespace=true` means you
don't have to `kubectl apply` the namespace manifests separately (though `k8s/namespaces/`
still exists for anyone applying manifests directly instead of via Argo CD).

Install Argo CD and apply both Applications:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl apply -f argocd/application-aws.yaml
kubectl apply -f argocd/application-google-cloud.yaml
```

## 9. AWS namespace simulation

`k8s/namespaces/aws.yaml` creates a plain `aws` Namespace on whatever cluster you apply it to
— this does not provision anything on real AWS; it's a local stand-in so the *portability* of
the chart can be demonstrated without needing two real cloud accounts.
`charts/cloudcrafter/values-aws.yaml` is a **minimal** overlay (not a full `values.yaml` copy)
— only `ingress.host` and `notificationsExternal.nodePort` differ, and only because both
simulated environments might be installed on one shared local cluster at once (see the
comments in that file for exactly why each one is necessary).

## 10. Google Cloud namespace simulation

Identical mechanism — `k8s/namespaces/google-cloud.yaml` and
`charts/cloudcrafter/values-google-cloud.yaml`, same reasoning, different namespace/host/port.

## 11. How to verify both deployments

```bash
kubectl apply -f k8s/namespaces/aws.yaml
kubectl apply -f k8s/namespaces/google-cloud.yaml

helm install cloudcrafter ./charts/cloudcrafter \
  --namespace aws -f charts/cloudcrafter/values-aws.yaml

helm install cloudcrafter ./charts/cloudcrafter \
  --namespace google-cloud -f charts/cloudcrafter/values-google-cloud.yaml

kubectl get pods -n aws
kubectl get pods -n google-cloud
helm list -A
```

Or, to prove the templates render correctly for both without installing anything:

```bash
helm template cloudcrafter ./charts/cloudcrafter -n aws -f charts/cloudcrafter/values-aws.yaml
helm template cloudcrafter ./charts/cloudcrafter -n google-cloud -f charts/cloudcrafter/values-google-cloud.yaml
```

Both commands use the exact same chart — the only inputs that differ are `-n` and `-f`.

## 12. Required GitHub repository settings

- **Actions permissions**: Settings → Actions → General → Workflow permissions → ensure
  "Read and write permissions" is enabled (needed for `release.yml` to push to GHCR using
  `GITHUB_TOKEN`).
- **Package visibility**: after the first successful `release.yml` run, go to the repository's
  Packages tab and confirm the four `cloudcrafter-*` packages exist; set visibility
  (public/private) as you prefer — private packages will additionally require pull
  credentials when Kubernetes actually pulls them.

## 13. Branch protection (you must enable this manually — I cannot change GitHub settings from
    within the repository)

Go to **Settings → Branches → Add branch protection rule** for `main`:

- ✅ Require a pull request before merging
- ✅ Require status checks to pass before merging, and require these exact checks (their
  names come directly from `ci.yml`'s job `name:` fields — they'll only appear in the list
  after `ci.yml` has run at least once on a PR):
  - `ci-summary` (recommended — one check that only passes if every matrix leg passed)
  - or, if you'd rather require every leg individually: `test-services (users, node 20.x)`,
    `test-services (events, node 20.x)`, `test-services (tickets, node 20.x)`,
    `test-services (notifications, node 20.x)`, `docker-build-validate (users)`, etc., and
    `helm-validate`
- ✅ Require branches to be up to date before merging

## 14. Required secrets

**None.** `release.yml` uses only the automatically-provided `secrets.GITHUB_TOKEN` — you do
not need to create any repository secret for CI/CD as implemented here. If you later point an
Argo CD Application at a *private* GHCR package, Argo CD's cluster will need an
`imagePullSecret` — not covered here since all packages are assumed public for this capstone.

# CI/CD

This section is the single reference for exactly what the CI/CD pipeline does. It
cross-references the more detailed explanations above (sections 3-7) rather than repeating
them, and documents what's new in Task 2B: explicit package.json/Kubernetes-YAML validation,
an in-image JWT-key-content check, and the `imagePullSecret` mechanism for private GHCR.

## What happens on a pull request

`.github/workflows/ci.yml` runs automatically. Nothing is deployed, nothing is published — it
only validates:

1. **`test-services`** (matrix: 4 services × Node 18.x/20.x) — validates each `package.json`
   parses as valid JSON, runs `npm install`, runs `node --check server.js` (syntax), runs
   `npm test` (see "Testing" above for what's covered).
2. **`k8s-validate`** — every file under `k8s/` (including `k8s/namespaces/`) is parsed as
   YAML and checked for the required `apiVersion`/`kind`/`metadata` fields
   (`.github/scripts/validate-k8s-yaml.py`). This does not need a live cluster or kubeconfig.
3. **`docker-build-validate`** (matrix: 4 services) — builds each Dockerfile (not pushed).
   For the `users` service specifically, an additional step runs the just-built image and
   checks that `/app/private.key`, `/app/public.key`, and `/app/keys/` do **not** exist inside
   it — a concrete, executed check that JWT key material never ends up baked into the image,
   not just a claim based on `.dockerignore` existing.
4. **`helm-validate`** — `helm lint`, `helm template` (default values, plus both the
   `values-aws.yaml` and `values-google-cloud.yaml` overlays), and a grep-based guard that
   fails the build if any chart *template* hardcodes `namespace: aws` or
   `namespace: google-cloud`.
5. **`ci-summary`** — depends on all of the above; the one check name to require in branch
   protection (see "Branch protection" above) if you don't want to enumerate every matrix leg.

No job in this workflow requires cloud credentials, a Docker Hub account, or cluster access.

## What happens on a push to `main`

Same `ci.yml` run as above, plus `.github/workflows/release.yml` triggers separately: builds
and pushes all four images to GHCR (see "GHCR image publishing" above for the full tagging
breakdown). CI and release are independent workflows — a CI failure on `main` doesn't block
the release workflow from also running, so branch protection (gating merges on CI passing) is
what actually prevents broken code from reaching `main` in the first place.

## How Kubernetes pulls the images

**If your GHCR packages are public** (the default unless you've explicitly restricted
visibility in the repo's Packages tab): nothing extra is needed. `imagePullSecrets` in
`values.yaml` defaults to `[]`, and Kubernetes pulls public GHCR images with no credentials.

**If your GHCR packages are private**, Kubernetes needs a pull secret:

```bash
# Create a GitHub PAT (classic) with only the "read:packages" scope at
# https://github.com/settings/tokens — do NOT use a broader-scoped token,
# and never commit this token anywhere.

kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<your-github-username> \
  --docker-password=<your-PAT-with-read:packages> \
  --docker-email=<your-email>
```

Then reference it when installing the chart:

```bash
helm install cloudcrafter ./charts/cloudcrafter \
  --set imageRegistry=ghcr.io/aliahmed08 \
  --set imageTag=1.0.0 \
  --set imagePullSecrets={ghcr-pull-secret}
```

This Secret must be created once per namespace/cluster you deploy into — it's cluster state,
not something this chart or repository ever creates or stores for you.

## Deploying a specific image version with Helm

```bash
# Deploy exactly the image built from commit abc1234:
helm upgrade --install cloudcrafter ./charts/cloudcrafter \
  --set imageRegistry=ghcr.io/aliahmed08 \
  --set imageTag=sha-abc1234

# Or deploy a tagged release:
helm upgrade --install cloudcrafter ./charts/cloudcrafter \
  --set imageRegistry=ghcr.io/aliahmed08 \
  --set imageTag=1.0.0
```

Because `imageTag` overrides every service's tag at once (see "GHCR + Helm integration"
above), a single `--set` is enough to move the whole release to a specific, immutable build.

## Required GitHub repository settings

Same as documented above under "Required GitHub repository settings" — Actions write
permissions for `GITHUB_TOKEN` (needed by `release.yml`), and reviewing package visibility
after the first release run.

## 15. Evidence commands

```bash
# CI ran and passed (after pushing/opening a PR):
#   GitHub -> Actions tab -> most recent "CI" run -> all green

# Images published:
#   GitHub -> repo -> Packages tab -> 4 cloudcrafter-* packages, each with a sha-<commit> tag

# Helm chart is valid:
helm lint ./charts/cloudcrafter
helm template cloudcrafter ./charts/cloudcrafter

# Both simulated environments render from the identical chart:
helm template cloudcrafter ./charts/cloudcrafter -n aws -f charts/cloudcrafter/values-aws.yaml
helm template cloudcrafter ./charts/cloudcrafter -n google-cloud -f charts/cloudcrafter/values-google-cloud.yaml

# Both are actually running (after `helm install` into each, or after Argo CD syncs):
kubectl get pods -n aws
kubectl get pods -n google-cloud

# Argo CD sees both Applications as Synced/Healthy:
kubectl get applications -n argocd
```
