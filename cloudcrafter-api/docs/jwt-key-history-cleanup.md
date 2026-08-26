# Purging compromised JWT keys from Git history

`services/users/private.key` and `services/users/public.key` were committed in this
repository's initial commit (`56bedd4`). Task 1 already removed them from the current
working tree (`git rm --cached`) and excluded them from future commits (`.gitignore`,
`.dockerignore`). That is enough to stop them from being copied into new clones' working
trees and new Docker images, **but the old key bytes are still recoverable from git history**
(`git show 56bedd4:services/users/private.key` would still print it) until history itself is
rewritten. Treat that old private key as permanently compromised — never re-add it, and never
paste its contents anywhere (chat, docs, commit messages, logs) while doing this cleanup.

## Recommended tool: git-filter-repo

`git filter-repo` is the tool the Git project itself recommends over the older `git
filter-branch` (which is slow and easy to misuse) and over BFG Repo-Cleaner (great for bulk
blob removal, but filter-repo is more precise for "delete these exact paths everywhere").

### 1. Install it

```bash
pip install git-filter-repo
# or: brew install git-filter-repo   (macOS)
```

### 2. Work from a **fresh, disposable clone** — never your daily working copy

History rewriting changes every commit hash downstream of the rewritten commit. Do this in a
throwaway clone so you don't corrupt your working directory mid-task:

```bash
git clone --no-local /path/to/cloudcrafter-api cloudcrafter-api-history-cleanup
cd cloudcrafter-api-history-cleanup
```

### 3. Strip the two files from every commit

```bash
git filter-repo --path services/users/private.key --path services/users/public.key --invert-paths
```

This rewrites every commit that ever touched those two paths, removing the blobs entirely —
not just deleting them in a new commit, but erasing them from history.

### 4. Verify they're actually gone

```bash
git log --all --oneline -- services/users/private.key services/users/public.key
# should print nothing

git rev-list --objects --all | grep -i "private.key\|public.key"
# should print nothing
```

### 5. Push the rewritten history

`git filter-repo` removes the `origin` remote as a safety measure (to stop an accidental
push of unrewritten history). Re-add it and force-push:

```bash
git remote add origin https://github.com/AliAhmed08/cloudcrafter-api.git
git push origin --force --all
git push origin --force --tags
```

### 6. Critical follow-up steps (these matter as much as the rewrite itself)

- **Every other clone/fork is now stale.** Anyone else with a copy of this repo (including
  your own other local clones) must re-clone fresh, or run `git fetch` + hard-reset — their
  old local history still has the key in it.
- **Rotate, don't reuse.** Never re-introduce the historical key pair. Generate a brand-new
  RS256 pair (Task 1 README, "Generate a local JWT key pair") and load only that into the
  Kubernetes Secret.
- **Assume it's already leaked.** Because it was in a public/shared repo, treat any tokens
  ever signed with that original private key as forgeable and not trustworthy, regardless of
  whether you rewrite history — history rewriting prevents *future* exposure from this repo,
  it does not retroactively secure anything that already happened.
- **GitHub caching**: GitHub itself may cache old commits reachable via PR references, forks,
  or its own internal object cache for a period after a force-push. For a genuinely
  compromised secret (as opposed to this training exercise), the correct real-world step is
  also to contact GitHub Support to request purging of cached views, in addition to the
  `filter-repo` push.

## Why not just `git rm` + new commit (what Task 1 did)?

That step was necessary but not sufficient — it stops *new* clones' working trees and new
Docker image builds from containing the key (correct for stopping ongoing exposure via the
active branch), but does not remove it from history. This document is the follow-up for
removing it from history entirely. Both steps are part of "safest possible" handling; this
file intentionally contains no key material itself.
