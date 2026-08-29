#!/usr/bin/env bash
# CloudCrafter JWT key rotation — three phases, run in order, each one
# followed by a full rollout before moving to the next. See
# docs/jwt-key-rotation.md for why three phases are needed for a genuinely
# zero-downtime rotation (the short version: every pod must learn to trust
# a new key BEFORE any pod starts signing with it).
#
# Usage:
#   ./scripts/rotate-jwt-keys.sh phase1   # generate a new key, add it as "previous" (trusted, not signing)
#   ./scripts/rotate-jwt-keys.sh phase2   # cut over: the new key becomes "current"
#   ./scripts/rotate-jwt-keys.sh phase3   # retire the old key entirely
#
# Requires: kubectl pointed at the right cluster/namespace, openssl.
# Never writes key material into this repository — only into a throwaway
# temp file that this script deletes itself, and into the live cluster's
# Secret (which is exactly where key material is supposed to live).

set -euo pipefail

PHASE="${1:-}"
SECRET_NAME="${SECRET_NAME:-users-jwt-keys}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-users}"

usage() {
  echo "Usage: $0 {phase1|phase2|phase3}"
  echo "Run phase1, wait for full rollout, then phase2, wait for full rollout, then phase3."
  exit 1
}

get_secret_field() {
  # Prints empty string (not an error) if the field doesn't exist yet —
  # used to check whether a "previous-*" field is currently present.
  kubectl get secret "$SECRET_NAME" -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true
}

case "$PHASE" in
  phase1)
    echo "== Phase 1: generate a new key, add it as 'previous' (trusted, NOT yet signing) =="

    if [ -n "$(get_secret_field previous-public.key)" ]; then
      echo "ERROR: a 'previous' key already exists in $SECRET_NAME — a rotation may already be in progress."
      echo "Run phase2 to complete it, or phase3 to retire it, before starting a new rotation."
      exit 1
    fi

    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT

    NEW_KID="key-$(date +%Y%m%d%H%M%S)"
    openssl genrsa -out "$TMPDIR/new-private.key" 2048 2>/dev/null
    openssl rsa -in "$TMPDIR/new-private.key" -pubout -out "$TMPDIR/new-public.key" 2>/dev/null

    # Stash the new private key + kid in a SEPARATE Secret (not users-jwt-keys
    # itself) purely so phase2 can retrieve it later — this is operational
    # state, not something committed anywhere.
    kubectl create secret generic users-jwt-keys-pending \
      --from-file=private.key="$TMPDIR/new-private.key" \
      --from-literal=kid="$NEW_KID" \
      --dry-run=client -o yaml | kubectl apply -f -

    kubectl patch secret "$SECRET_NAME" --type=merge -p="{\"data\":{\"previous-public.key\":\"$(base64 -w0 "$TMPDIR/new-public.key")\",\"previous-kid\":\"$(echo -n "$NEW_KID" | base64 -w0)\"}}"

    kubectl rollout restart "deployment/$DEPLOYMENT_NAME"
    echo
    echo "Waiting for rollout to complete — every pod must pick this up before phase2:"
    kubectl rollout status "deployment/$DEPLOYMENT_NAME"

    echo
    echo "Phase 1 complete. New kid: $NEW_KID (now trusted for verification, not yet signing)."
    echo "Next: run './scripts/rotate-jwt-keys.sh phase2' once you're ready to cut over."
    ;;

  phase2)
    echo "== Phase 2: cut over — the new key becomes 'current', the old 'current' becomes 'previous' =="

    NEW_PRIVATE_KEY="$(kubectl get secret users-jwt-keys-pending -o jsonpath='{.data.private\.key}' | base64 -d)"
    NEW_KID="$(kubectl get secret users-jwt-keys-pending -o jsonpath='{.data.kid}' | base64 -d)"
    if [ -z "$NEW_KID" ]; then
      echo "ERROR: no pending rotation found (users-jwt-keys-pending Secret missing). Run phase1 first."
      exit 1
    fi

    NEW_PUBLIC_KEY="$(get_secret_field previous-public.key)"
    OLD_CURRENT_PUBLIC="$(get_secret_field current-public.key)"
    OLD_CURRENT_KID="$(get_secret_field current-kid)"

    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT
    printf '%s' "$NEW_PRIVATE_KEY" > "$TMPDIR/new-private.key"
    printf '%s' "$NEW_PUBLIC_KEY" > "$TMPDIR/new-public.key"

    kubectl patch secret "$SECRET_NAME" --type=merge -p="{\"data\":{\
\"current-private.key\":\"$(base64 -w0 "$TMPDIR/new-private.key")\",\
\"current-public.key\":\"$(base64 -w0 "$TMPDIR/new-public.key")\",\
\"current-kid\":\"$(echo -n "$NEW_KID" | base64 -w0)\",\
\"previous-public.key\":\"$(printf '%s' "$OLD_CURRENT_PUBLIC" | base64 -w0)\",\
\"previous-kid\":\"$(printf '%s' "$OLD_CURRENT_KID" | base64 -w0)\"\
}}"

    kubectl rollout restart "deployment/$DEPLOYMENT_NAME"
    echo
    echo "Waiting for rollout to complete:"
    kubectl rollout status "deployment/$DEPLOYMENT_NAME"

    kubectl delete secret users-jwt-keys-pending

    echo
    echo "Phase 2 complete. New logins now sign with kid=$NEW_KID."
    echo "The old key (kid=$OLD_CURRENT_KID) is still trusted, so tokens issued before this"
    echo "cutover remain valid. Wait at least the token TTL (1h) before running phase3."
    ;;

  phase3)
    echo "== Phase 3: retire the old key entirely =="

    OLD_KID="$(get_secret_field previous-kid)"
    if [ -z "$OLD_KID" ]; then
      echo "Nothing to retire — no 'previous' key currently in $SECRET_NAME."
      exit 0
    fi

    kubectl patch secret "$SECRET_NAME" --type=json -p='[
      {"op": "remove", "path": "/data/previous-public.key"},
      {"op": "remove", "path": "/data/previous-kid"}
    ]'

    kubectl rollout restart "deployment/$DEPLOYMENT_NAME"
    echo
    echo "Waiting for rollout to complete:"
    kubectl rollout status "deployment/$DEPLOYMENT_NAME"

    echo
    echo "Phase 3 complete. Tokens signed with the retired key (kid=$OLD_KID) will now be rejected."
    ;;

  *)
    usage
    ;;
esac
