# Add native support for mounting blocklist.json and allowlist.json via Helm values

## Problem

NORA supports curation blocklist and allowlist JSON files (`curation.blocklist_path`, `curation.allowlist_path`), but the Helm chart has no way to mount these files into the pod without a manual `kubectl patch` or `kubectl cp` workaround.

The chart already solves this exact problem for htpasswd — `config.auth.htpasswd.existingSecret` mounts a Secret key as a file. The same pattern is needed for blocklist/allowlist.

## Proposed Solution

Add two new fields under `config.curation`:

```yaml
config:
  curation:
    mode: "enforce"
    blocklist:
      existingSecret: "nora-blocklist"    # or existingConfigMap
      secretKey: "blocklist.json"
      mountPath: "/etc/nora"
    allowlist:
      existingSecret: "nora-allowlist"
      secretKey: "allowlist.json"
      mountPath: "/etc/nora"
```

The chart should:

1. Create the volume from the Secret/ConfigMap.
2. Mount the file at `<mountPath>/<secretKey>`.
3. Set `blocklist_path` / `allowlist_path` in the generated config automatically, so the user doesn't need to specify the path in two places.
4. Support both `existingSecret` and `existingConfigMap` (same as htpasswd pattern).

## Current workaround

Without this, users must:

```bash
kubectl create configmap nora-blocklist --from-file=blocklist.json=blocklist.json
```

Then manually patch the Deployment:

```yaml
# nora-blocklist-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nora
spec:
  template:
    spec:
      containers:
        - name: nora
          volumeMounts:
            - name: blocklist
              mountPath: /etc/nora/blocklist.json
              subPath: blocklist.json
              readOnly: true
      volumes:
        - name: blocklist
          configMap:
            name: nora-blocklist
```

```bash
kubectl patch deployment nora --type=merge --patch-file=nora-blocklist-patch.yaml
```

This is fragile — the patch must be reapplied on every `helm upgrade`, and the container name must match exactly.

## Alternatives considered

- **`extraVolumeMounts` / `extraVolumes`** — generic escape hatch. Useful but doesn't auto-wire `blocklist_path` in the config. Would still be a welcome addition.
- **Inline blocklist in values** — would require the chart to render a ConfigMap from inline JSON. More convenient but couples the blocklist lifecycle to `helm upgrade`.

## Context

- Curation blocklist reference: https://getnora.dev/configuration/curation/
- Config field: `curation.blocklist_path` (TOML) / `NORA_CURATION_BLOCKLIST_PATH` (env)
- Config field: `curation.allowlist_path` (TOML) / `NORA_CURATION_ALLOWLIST_PATH` (env)
