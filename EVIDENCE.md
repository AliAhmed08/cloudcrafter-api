# CloudCrafter — Capstone Evidence

This document is the single index of what was built and exactly how to verify each piece
yourself. It does not claim anything was verified that wasn't — see each section's "Verified"
vs "Requires your machine" split.

## 1. Kubernetes deployment (Task 1)

Raw manifests: `k8s/*.yaml`. Deploy: `kubectl apply -f k8s/`. Verify:
```bash
kubectl get pods
kubectl get svc
```
**Verified:** all manifests are structurally valid YAML with required fields
(`.github/scripts/validate-k8s-yaml.py`, also run in CI). **Requires your machine:** pods
actually reaching `Running`/`Ready` (needs a real cluster).

## 2. Helm deployment (Task 2A)

Chart: `charts/cloudcrafter/`. Deploy: `helm install cloudcrafter ./charts/cloudcrafter`
(after creating the JWT Secret — see `docs/jwt-key-rotation.md` "Creating the initial
Secret"). **Verified:** every template parses successfully under Go's real `text/template`
engine (installed via `apt` in the sandbox used to build this) — confirmed via a script that
loads the whole `templates/` directory as one associated template set with Sprig-equivalent
function stubs registered, the same way Helm itself does it internally. **Requires your
machine:** `helm lint`/`helm template`/`helm install` with the real Helm binary (unavailable
in the sandbox that built this).

## 3. CI/CD (Task 2B / Phase 3)

`.github/workflows/ci.yml` (test/build/lint on PR + push to main),
`.github/workflows/release.yml` (GHCR publish). **Verified:** both parse as valid YAML;
`.github/scripts/validate-k8s-yaml.py` (the script CI calls) actually run against the real
`k8s/` directory. **Requires GitHub Actions:** the workflows actually executing on GitHub's
runners.

## 4. GHCR (Phase 3)

Images: `ghcr.io/<owner>/cloudcrafter-{users,events,tickets,notifications}`, tagged
`sha-<commit>` always, plus semver tags on version-tagged releases. **Requires GitHub
Actions:** an actual publish run.

## 5. Testing (Phase 4)

22 tests across 4 services, using only Node's built-in `node:test`/`assert`/`fetch` (no
framework dependency). **Verified — actually run in this session:**
- `events`: 6/6 pass
- `notifications`: 4/4 pass
- `tickets`: 4/4 pass
- `users`: 8/8 pass (includes the full JWT rotation lifecycle test)

```bash
for svc in users events tickets notifications; do
  (cd services/$svc && npm install && npm test)
done
```

## 6. Argo CD / GitOps (Phase 5)

`argocd/application-aws.yaml`, `argocd/application-google-cloud.yaml` — both point at this
repo's `charts/cloudcrafter`, both use `syncPolicy.automated.{prune,selfHeal}`. **Verified:**
valid YAML, correct `repoURL`/`path`/`destination` fields. **Requires your machine:** an
actual Argo CD install + these Applications actually syncing.

```bash
kubectl apply -f argocd/application-aws.yaml
kubectl apply -f argocd/application-google-cloud.yaml
kubectl get applications -n argocd
```

## 7. Multi-environment (Phase 6)

`k8s/namespaces/{aws,google-cloud}.yaml`, `charts/cloudcrafter/values-{aws,google-cloud}.yaml`
(minimal overlays — only `ingress.host` and `notificationsExternal.nodePort` differ, to avoid
collisions if both are installed on one shared demo cluster). **Verified:** no chart template
hardcodes either namespace name (grep-checked, and CI enforces this same check on every PR).

```bash
helm template cloudcrafter ./charts/cloudcrafter -n aws -f charts/cloudcrafter/values-aws.yaml
helm template cloudcrafter ./charts/cloudcrafter -n google-cloud -f charts/cloudcrafter/values-google-cloud.yaml
```

## 8. Monitoring (Phase 7)

`services/*/metrics.js` + `/metrics` on all four services (prom-client). **Verified — actually
run in this session:** started a real events service instance, made real HTTP requests, and
confirmed `/metrics` returns genuine Prometheus-format output including
`http_requests_total`/`http_request_duration_seconds` correctly labeled per-route (e.g.
`/events/:id`, not raw high-cardinality paths).

`observability/prometheus/` (scrape config + Deployment), `observability/grafana/` (Deployment
+ provisioned Prometheus AND Loki datasources + a 5-panel dashboard combining metrics and
logs — request rate, error rate, p95 latency, total requests, plus a live logs panel querying
Loki across all four services), `observability/loki/` (Loki + Promtail DaemonSet for log
collection). **Verified:** all manifests structurally valid YAML; the dashboard JSON is valid
JSON with 5 real panels (4 metrics + 1 logs), each with an explicit datasource reference
(`prometheus-datasource` / `loki-datasource` UIDs) matching the provisioned datasource
ConfigMap. **Requires your machine:**

```bash
kubectl apply -f observability/prometheus/
kubectl apply -f observability/grafana/
kubectl apply -f observability/loki/
kubectl port-forward svc/grafana 3000:3000
# open http://localhost:3000, dashboard: CloudCrafter -> CloudCrafter — Service Overview
```

## 9. JWT rotation (Phase 8)

`services/users/server.js` supports `current`/`previous` RS256 key pairs identified by `kid`.
**Verified — actually run in this session:** a dedicated test
(`services/users/test/jwt-rotation.test.js`) exercises the real server code through all three
rotation phases (pre-rotation → grace period → retired), confirming: a token survives the
phase 1→2 cutover unchanged, remains valid through the cutover, and is rejected only after
phase 3 retires the old key. Both rotation tests pass.

```bash
./scripts/rotate-jwt-keys.sh phase1   # wait for full rollout
./scripts/rotate-jwt-keys.sh phase2   # wait at least 1 hour (token TTL)
./scripts/rotate-jwt-keys.sh phase3
```

See `docs/jwt-key-rotation.md` for why three phases are required for zero downtime.

## 10. Event-driven architecture (Task 1, re-verified here)

Ticket creation → S3 upload (required to succeed, not best-effort) → S3 `ObjectCreated` event
→ Lambda → `POST /notify` → notification visible in `GET /notifications`, with no manual
Lambda invocation and no manual `/notify` call anywhere in the test path.
`test/verify-task1.sh` proves this chain specifically, with independent checks for each hop
(S3 object exists, Lambda actually ran — checked via its own CloudWatch logs, not inferred —
then the notification appears), each with retry/backoff for LocalStack's Lambda cold start.

## Full end-to-end demo

`test/integration/e2e.sh` runs the complete flow in one script:

```
Login -> JWT -> authenticated /protected request
  -> create event -> create ticket -> receipt to S3
    -> S3 event -> Lambda -> Notifications -> notification appears
      -> Prometheus has scraped metrics for this run
```

```bash
BASE_URL=http://cloudcrafter.local ./test/integration/e2e.sh
```

**Verified:** the script's retry/check helper logic was tested in isolation and behaves
correctly (succeeds once a condition becomes true within budget, correctly reports exhaustion
as failure). **Requires your machine:** the full script against a real, fully-deployed
environment (Minikube + LocalStack + Lambda + Prometheus all up) — this needs everything above
running simultaneously, which no sandbox in this conversation has had access to.

## Security hardening (Phase 9)

- Non-root containers: `podSecurityContext.runAsNonRoot: true` + `runAsUser: 1000`, matching
  the non-root `node` user the Dockerfiles already run as.
- `containerSecurityContext`: `allowPrivilegeEscalation: false`, all Linux capabilities
  dropped, `readOnlyRootFilesystem: true` (a `/tmp` emptyDir is mounted on every container for
  any scratch space needed — confirmed by code review that none of the four services write to
  disk at runtime; this specific claim still needs a real container run to fully confirm, see
  below).
- `NetworkPolicy` (`k8s/network-policies.yaml`): default-deny ingress, explicit allows for the
  Ingress controller, Prometheus scraping, and the LocalStack Lambda's NodePort path. **Scoped
  to ingress only, not egress** — documented explicitly in the file as a deliberate tradeoff
  (egress restriction risks silently breaking the LocalStack event flow in ways that vary by
  Minikube driver).
- Image pinning: `node:18-alpine` (major-version pinned, not `latest`) — not pinned to an exact
  patch/digest; noted as a possible further hardening step, not implemented, rather than
  silently left undocumented.
- Secrets: JWT keys and S3 credentials only ever come from Kubernetes Secrets or environment
  variables — never committed. Verified via repeated `git ls-files | grep -E '\.(key|pem)$'`
  checks (must be empty) throughout this project's history.

**Requires your machine:** actually running a container with
`readOnlyRootFilesystem: true` to confirm nothing unexpectedly needs to write outside `/tmp`;
confirming your cluster's CNI actually enforces `NetworkPolicy` (Minikube's default CNI does
not — see README.md "Security" for how to check).
