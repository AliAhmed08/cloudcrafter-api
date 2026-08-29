# JWT Key Rotation

## How the Users service supports rotation

`services/users/server.js` reads up to two RS256 key pairs from the mounted
Secret (`users-jwt-keys`), each identified by a "kid" (key ID):

| Secret key             | Required? | Purpose                                    |
|-------------------------|-----------|---------------------------------------------|
| `current-private.key`   | yes       | signs new tokens                             |
| `current-public.key`    | yes       | verifies tokens signed by the current key    |
| `current-kid`           | yes       | the kid embedded in newly-signed tokens      |
| `previous-public.key`   | no        | verifies tokens signed by a since-retired key |
| `previous-kid`          | no        | the kid that maps to `previous-public.key`   |

Every new token is signed with `current-private.key` and tagged with
`current-kid` in its JWT header. `GET /protected` reads the token's `kid`
and picks whichever public key matches — current or previous — to verify
against. A token with an unrecognized kid is rejected (403).

The `previous-*` fields are **optional** — the Kubernetes Secret volume
mount has no `items` restriction specifically so the pod doesn't fail to
start when they're absent, which is the normal (non-rotating) state.

## Why rotation happens in three phases

A naive "just swap the key and restart" rotation is not zero-downtime: with
multiple replicas, a `kubectl rollout restart` brings pods down one at a
time, so old and new pods run simultaneously for a while. If a new pod signs
a token with a key that an old pod (mid-rollout) has never heard of, that
old pod will reject the token — a real, user-visible failure during the
rollout window.

The fix is to make every pod **trust** the new key before any pod starts
**signing** with it:

1. **Phase 1 — introduce the new key as trusted, not yet signing.** The new
   public key is added to the `previous-*` slot (yes, even though it's
   newer — that slot just means "a second trusted key," not "older"). Every
   pod is rolled and now trusts both the old key (still signing) and the
   new key (not signing yet). No token can go unverified during this
   rollout, because nothing has started using the new key yet.
2. **Phase 2 — cut over.** The new key becomes `current` (starts signing);
   the old key moves into `previous` (still trusted for verification). Every
   pod is rolled. During this rollout, some pods sign with the old key, some
   with the new — irrelevant, because every pod (from phase 1 onward)
   already trusts both.
3. **Phase 3 — retire the old key**, once you're confident no token signed
   before the phase 2 cutover is still unexpired (wait at least the token
   TTL — 1 hour in this project — plus a safety margin). The `previous-*`
   fields are removed entirely. Tokens signed by the retired key now fail.

This is exactly what `test/users/jwt-rotation.test.js` exercises against the
real server code (not a mock): a token survives phase 1→2 unchanged, remains
valid through the phase 2 cutover, and is rejected only after phase 3.

## Running a rotation

```bash
./scripts/rotate-jwt-keys.sh phase1
# wait for rollout to complete (the script does this and prints progress)

./scripts/rotate-jwt-keys.sh phase2
# wait at least 1 hour (the token TTL) before proceeding

./scripts/rotate-jwt-keys.sh phase3
```

The script generates key material into a throwaway temp file it deletes
itself, and reads/writes only the live cluster's `users-jwt-keys` Secret —
nothing is ever written into this repository. It requires `kubectl`
pointed at the right cluster and `openssl`.

## Creating the initial Secret (first-time setup, no rotation involved)

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

No `previous-*` files exist yet — that's correct; they only appear during
an active rotation.
