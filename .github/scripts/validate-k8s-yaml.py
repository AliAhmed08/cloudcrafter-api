#!/usr/bin/env python3
"""
Validates every YAML file under k8s/ (including k8s/namespaces/):
  - must parse as valid YAML
  - every document must have apiVersion, kind, and metadata

This is a deliberately simple static check — it does not require a live
cluster, kubeconfig, or any cloud credentials. It is not a substitute for
`kubectl apply --dry-run=server` against a real API server, but it does
catch the class of mistakes (typos, bad indentation, missing required
top-level fields) that are most likely to slip into a PR.
"""
import glob
import sys

import yaml

def main():
    files = sorted(glob.glob("k8s/**/*.yaml", recursive=True))
    if not files:
        print("::error::No YAML files found under k8s/ — expected the Task 1 baseline manifests.")
        return 1

    failed = False
    for path in files:
        try:
            docs = [d for d in yaml.safe_load_all(open(path)) if d is not None]
        except yaml.YAMLError as exc:
            print(f"::error::{path}: invalid YAML: {exc}")
            failed = True
            continue

        file_ok = True
        for doc in docs:
            missing = [f for f in ("apiVersion", "kind", "metadata") if f not in doc]
            if missing:
                print(f"::error::{path}: document missing required field(s): {missing}")
                failed = True
                file_ok = False

        if file_ok:
            print(f"OK: {path}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
