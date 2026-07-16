# Convert `kopiur` to KRO ResourceGraphDefinitions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `kubernetes/components/kopiur/**` with a single KRO `ResourceGraphDefinition` (`KopiurBackup`), so each consumer app renders one `KopiurBackup` instance instead of multiple raw kopiur CRs. App `ks.yaml` files are not touched.

**Architecture:** One RGD defines a namespaced `KopiurBackup` API with `spec.scope: enum{local, remote, both}` and seven coarse knobs (`pvcName`, `capacity`, `storageClass`, `accessModes`, `snapshotClass`, `puid`, `pgid`). Six resource templates (PVC, Restore, two SnapshotPolicies + two SnapshotSchedules), with `includeWhen` toggling the local/remote policy+schedule pair. The Restore's `fromPolicy.name` is a CEL ternary on `scope`. The three kustomize `Component`s render three thin instance templates (one per `scope` value), replacing today's `base/...` subtree.

**Tech Stack:** Kubernetes YAML, KRO v0.9.2 RGD (CEL + `includeWhen`), Kustomize `Component` (`kind: Component`), Flux v2 + ResourceSet, kubeconform, kubectl.

## Global Constraints

- kro v0.9.2 API (`kro.run/v1alpha1`), `ResourceGraphDefinition` cluster-scoped CRs.
- Kopiur CRDs: `kopiur.home-operations.com/v1alpha1` — `Restore`, `SnapshotPolicy`, `SnapshotSchedule`, `ClusterRepository`.
- Flux `Kustomization` namespaces: per-app via `spec.targetNamespace`; kustomize auto-applies to resources without `metadata.namespace`.
- 29 consumer apps — none of their `ks.yaml` files are modified.
- `puid`/`pgid` declared `string` in RGD schema; instance templates coerce via `${int(...)}`. (Verified in Task 1: `string` accepts both quoted and unquoted Flux substitutes; `integer` rejects the quoted form.)
- `scope: enum{local, remote, both}` default `"both"`.
- All file paths below are relative to repo root `/home/m00n/Documents/Projects/homelab-cluster`.

## File Structure (delta)

| Action | Path                                                                                          |
| ------ | --------------------------------------------------------------------------------------------- |
| Create | `kubernetes/apps/kopiur-system/kopiur/config/kopiurbackup-rgd.yaml`                           |
| Create | `kubernetes/components/kopiur/instance.yaml`                                                  |
| Create | `kubernetes/components/kopiur/local/instance.yaml`                                            |
| Create | `kubernetes/components/kopiur/remote/instance.yaml`                                           |
| Modify | `kubernetes/components/kopiur/kustomization.yaml`                                             |
| Modify | `kubernetes/components/kopiur/local/kustomization.yaml`                                       |
| Modify | `kubernetes/components/kopiur/remote/kustomization.yaml`                                      |
| Modify | `kubernetes/apps/kopiur-system/kopiur/config/kustomization.yaml`                              |
| Delete | `kubernetes/components/kopiur/base/` (entire subtree)                                         |
| Delete | `kubernetes/components/kopiur/remote/restore.yaml`                                            |
| Delete | `kubernetes/apps/kopiur-system/kopiur/config/resourcegraphdefinition.yaml` (untracked sample) |

---

## Task 1 — Verify kro 0.9.2 RGD API surfaces used in the design

**Files:** none (read-only)

**Interfaces:** none

- [ ] **Step 1: Confirm CEL `int(string)` coercion is supported in v0.9.2**

    Run against the running cluster (or the docs):

    ```bash
    kubectl exec -n kro-system deploy/kro-controller -- \
      kroctl eval --expr 'int("10000")'
    ```

    Expected: returns `10000` as `int64`. If `kroctl eval` is unavailable, instead inspect the `kro-controller` logs after applying the RGD with a sample instance; or use `kustomize build` followed by `kubeconform` (Step 4) — kro only sees the resolved YAML.

- [ ] **Step 2: Confirm `includeWhen` accepts CEL boolean expressions referencing `schema.spec.*`**

    Pull the kro v0.9.2 docs (`docs/concepts/rgd/02-resource-definitions/02-include-when.md` from `kro.run` for the pinned version). Confirm the syntactic form `${schema.spec.scope == "local" || schema.spec.scope == "both"}`.

- [ ] **Step 3: Confirm `ResourceGraphDefinition` scope vs. where it can live**

    Pull the docs: `ResourceGraphDefinition` itself is a **cluster-scoped** CR. It must be applied at cluster scope, but the _instances_ it generates can be namespaced. Verify that placing `kopiurbackup-rgd.yaml` under `kubernetes/apps/kopiur-system/kopiur/config/` (whose Flux `Kustomization` has no `targetNamespace` — see `kubernetes/apps/kopiur-system/kopiur/ks.yaml:25-43`) is sufficient. If not, the file gets moved to a cluster-scoped Flux `Kustomization` in `kubernetes/flux/cluster/`.

- [ ] **Step 4: Capture verification notes**

    Write a 5-line summary into commit message body for Task 4 referencing any API gotchas discovered.

---

## Task 2 — Add the `KopiurBackup` RGD definition

**Files:**

- Create: `kubernetes/apps/kopiur-system/kopiur/config/kopiurbackup-rgd.yaml` — the RGD definition (full body in this task's Step 1, validated against kro v0.9.2; see "Adjustments from Task 1" below the body).
- Modify: `kubernetes/apps/kopiur-system/kopiur/config/kustomization.yaml`

**Interfaces:**

- Produces: a registered `KopiurBackup` CRD in the cluster.

- [ ] **Step 1: Create the RGD file**

    Write `kubernetes/apps/kopiur-system/kopiur/config/kopiurbackup-rgd.yaml`:

    ```yaml
    ---
    # yaml-language-server: $schema=https://k8s-schemas.m00nlit.dev/kro.run/resourcegraphdefinition_v1alpha1.json
    apiVersion: kro.run/v1alpha1
    kind: ResourceGraphDefinition
    metadata:
      name: kopiurbackup
    spec:
      schema:
        apiVersion: v1alpha1
        kind: KopiurBackup
        scope: Namespaced
        spec:
      scope:         string  | enum="local,remote,both" default="both"
      pvcName:       string  | default=${schema.metadata.name}
      capacity:      string  | default="5Gi"
      storageClass:  string  | default="zfs-spark"
      accessModes:   []string | default=["ReadWriteOnce"]
      snapshotClass: string  | default="csi-zfs"
      puid:          string  | default="1000"
      pgid:          string  | default="1000"
      # Schema gotcha (Task 1 finding A): kro SimpleSchema's `enum{...}` is
      # rejected at admission; use `string | enum="a,b,c" default="x"`.
      # Schema gotcha (Task 1 finding B): `puid`/`pgid` are `string` (not
      # `integer`) so Flux substitutes work whether quoted or unquoted;
      # the existing `${int(...)}` CEL at every destination does the
      # string→int64 coercion.
      resources:
        - id: pvc
          template:
            apiVersion: v1
            kind: PersistentVolumeClaim
            metadata:
              name: ${schema.spec.pvcName}
              annotations:
                kustomize.toolkit.fluxcd.io/prune: disabled
            spec:
              accessModes: ${schema.spec.accessModes}
              dataSourceRef:
                apiVersion: kopiur.home-operations.com/v1alpha1
                kind: Restore
                name: ${schema.metadata.name}
              resources:
                requests:
                  storage: ${schema.spec.capacity}
              storageClassName: ${schema.spec.storageClass}
        - id: restore
          template:
            apiVersion: kopiur.home-operations.com/v1alpha1
            kind: Restore
            metadata:
              name: ${schema.metadata.name}
            spec:
              policy: { onMissingSnapshot: Continue }
              source:
                fromPolicy:
                  name: ${schema.spec.scope == "remote" ? schema.metadata.name + "-b2" : schema.metadata.name}
                  offset: 0
              target: { populator: {} }
              mover:
                securityContext:
                  runAsNonRoot: true
                  runAsUser:  ${int(schema.spec.puid)}
                  runAsGroup: ${int(schema.spec.pgid)}
                podSecurityContext:
                  fsGroup: ${int(schema.spec.pgid)}
                  fsGroupChangePolicy: OnRootMismatch
        - id: localPolicy
          includeWhen:
            - ${schema.spec.scope == "local" || schema.spec.scope == "both"}
          template:
            apiVersion: kopiur.home-operations.com/v1alpha1
            kind: SnapshotPolicy
            metadata: { name: ${schema.metadata.name} }
            spec:
              repository: { kind: ClusterRepository, name: garage }
              retention:  { keepDaily: 7, keepHourly: 24 }
              compression:{ compressor: zstd }
              sources:
                - pvc: { name: ${schema.spec.pvcName} }
              verification:
                deep:
                  capacity: ${schema.spec.capacity}
                  schedule: { cron: "H 5 1 * *" }
                quick:
                  schedule: { cron: "H 3 * * *" }
              volumeSnapshotClassName: ${schema.spec.snapshotClass}
              mover:
                securityContext:
                  runAsNonRoot: true
                  runAsUser:  ${int(schema.spec.puid)}
                  runAsGroup: ${int(schema.spec.pgid)}
                podSecurityContext:
                  fsGroup: ${int(schema.spec.pgid)}
                  fsGroupChangePolicy: OnRootMismatch
        - id: localSchedule
          includeWhen:
            - ${schema.spec.scope == "local" || schema.spec.scope == "both"}
          template:
            apiVersion: kopiur.home-operations.com/v1alpha1
            kind: SnapshotSchedule
            metadata: { name: ${schema.metadata.name} }
            spec:
              policyRef: { name: ${schema.metadata.name} }
              schedule:  { cron: "H * * * *" }
        - id: remotePolicy
          includeWhen:
            - ${schema.spec.scope == "remote" || schema.spec.scope == "both"}
          template:
            apiVersion: kopiur.home-operations.com/v1alpha1
            kind: SnapshotPolicy
            metadata: { name: ${schema.metadata.name + "-b2"} }
            spec:
              repository: { kind: ClusterRepository, name: b2 }
              retention:  { keepDaily: 7 }
              compression:{ compressor: zstd }
              sources:
                - pvc: { name: ${schema.spec.pvcName} }
              verification:
                deep:
                  capacity: ${schema.spec.capacity}
                  schedule: { cron: "H 5 1 * *" }
                quick:
                  schedule: { cron: "H 3 * * *" }
              volumeSnapshotClassName: ${schema.spec.snapshotClass}
              mover:
                securityContext:
                  runAsNonRoot: true
                  runAsUser:  ${int(schema.spec.puid)}
                  runAsGroup: ${int(schema.spec.pgid)}
                podSecurityContext:
                  fsGroup: ${int(schema.spec.pgid)}
                  fsGroupChangePolicy: OnRootMismatch
        - id: remoteSchedule
          includeWhen:
            - ${schema.spec.scope == "remote" || schema.spec.scope == "both"}
          template:
            apiVersion: kopiur.home-operations.com/v1alpha1
            kind: SnapshotSchedule
            metadata: { name: ${schema.metadata.name + "-b2"} }
            spec:
              policyRef: { name: ${schema.metadata.name + "-b2"} }
              schedule:  { cron: "H 0 * * *" }
    ```

- [ ] **Step 2: Update the config kustomization to point at the new RGD**

    Edit `kubernetes/apps/kopiur-system/kopiur/config/kustomization.yaml`:

    ```yaml
    ---
    # yaml-language-server: $schema=https://json.schemastore.org/kustomization
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
        - ./clusterrepository.yaml
        - ./externalsecret.yaml
        - ./httproute.yaml
        - ./kopiurbackup-rgd.yaml
    ```

- [ ] **Step 3: Build and validate**

    ```bash
    kubectl --dry-run=client -f kubernetes/apps/kopiur-system/kopiur/config/kopiurbackup-rgd.yaml
    kustomize build kubernetes/apps/kopiur-system/kopiur/config | kubeconform -summary
    ```

    Expected: `kopiurbackup-rgd.yaml` parses; kubeconform reports 0 errors against the kro and kopiur schemas.

- [ ] **Step 4: Commit**

    ```bash
    git add kubernetes/apps/kopiur-system/kopiur/config/kopiurbackup-rgd.yaml \
            kubernetes/apps/kopiur-system/kopiur/config/kustomization.yaml
    git commit -m "feat(kopiur): add KopiurBackup ResourceGraphDefinition"
    ```

---

## Task 3 — Add the three per-specialisation instance templates

**Files:**

- Create: `kubernetes/components/kopiur/instance.yaml` (scope: both)
- Create: `kubernetes/components/kopiur/local/instance.yaml` (scope: local)
- Create: `kubernetes/components/kopiur/remote/instance.yaml` (scope: remote)

**Interfaces:**

- Produces: three yaml files that Kustomize renders into a single `KopiurBackup` instance each, fed by `${APP}` from the per-app Flux `postBuild.substitute`.

- [ ] **Step 1: Create `kubernetes/components/kopiur/instance.yaml`**

    ```yaml
    ---
    # yaml-language-server: $schema=https://k8s-schemas.m00nlit.dev/kro.run/kopiurbackup_v1alpha1.json
    apiVersion: kro.run/v1alpha1
    kind: KopiurBackup
    metadata:
      name: ${APP}
    spec:
      pvcName:      ${KOPIUR_PVC:=${APP}}
      capacity:     ${KOPIUR_CAPACITY:=5Gi}
      storageClass: ${KOPIUR_STORAGECLASS:=zfs-spark}
      accessModes:
        - ${KOPIUR_ACCESSMODES:=ReadWriteOnce}
      snapshotClass:${KOPIUR_SNAPSHOTCLASS:=csi-zfs}
      puid:         ${KOPIUR_PUID:=${PUID:=1000}}
      pgid:         ${KOPIUR_PGID:=${PGID:=1000}}
    ```

- [ ] **Step 2: Create `kubernetes/components/kopiur/local/instance.yaml`**

    Same as Step 1, plus:

    ```yaml
    scope: local
    ```

    (Insert as the first key in `spec:`.)

- [ ] **Step 3: Create `kubernetes/components/kopiur/remote/instance.yaml`**

    Same as Step 1, plus:

    ```yaml
    scope: remote
    ```

    (Insert as the first key in `spec:`.)

- [ ] **Step 4: Sanity-check kustomize substitution**

    Simulate what Flux does for the continuwuity app (KOPIUR_CAPACITY=8Gi, no other overrides):

    ```bash
    POSTBUILD_APP=continuwuity POSTBUILD_KOPIUR_CAPACITY=8Gi \
      kustomize build --enable-helm kubernetes/components/kopiur/local \
        | grep -A1 'pvcName:'
    ```

    Expected: `pvcName: continuwuity` (uses the schema default).

- [ ] **Step 5: Commit**

    ```bash
    git add kubernetes/components/kopiur/instance.yaml \
            kubernetes/components/kopiur/local/instance.yaml \
            kubernetes/components/kopiur/remote/instance.yaml
    git commit -m "feat(kopiur): add per-specialisation KopiurBackup instance templates"
    ```

---

## Task 4 — Switch the three Components to render instance templates

**Files:**

- Modify: `kubernetes/components/kopiur/kustomization.yaml`
- Modify: `kubernetes/components/kopiur/local/kustomization.yaml`
- Modify: `kubernetes/components/kopiur/remote/kustomization.yaml`

**Interfaces:**

- Consumes: per-app Flux `Kustomization.spec.components` paths to `components/kopiur`, `components/kopiur/local`, `components/kopiur/remote` (unchanged).

- [ ] **Step 1: Rewrite the root Component kustomization**

    `kubernetes/components/kopiur/kustomization.yaml`:

    ```yaml
    ---
    # yaml-language-server: $schema=https://json.schemastore.org/kustomization
    apiVersion: kustomize.config.k8s.io/v1alpha1
    kind: Component
    resources:
        - ./instance.yaml
    ```

- [ ] **Step 2: Rewrite the local Component kustomization**

    `kubernetes/components/kopiur/local/kustomization.yaml`:

    ```yaml
    ---
    # yaml-language-server: $schema=https://json.schemastore.org/kustomization
    apiVersion: kustomize.config.k8s.io/v1alpha1
    kind: Component
    resources:
        - ./instance.yaml
    ```

- [ ] **Step 3: Rewrite the remote Component kustomization**

    `kubernetes/components/kopiur/remote/kustomization.yaml`:

    ```yaml
    ---
    # yaml-language-server: $schema=https://json.schemastore.org/kustomization
    apiVersion: kustomize.config.k8s.io/v1alpha1
    kind: Component
    resources:
        - ./instance.yaml
    ```

- [ ] **Step 4: Validate one full app's rendered output**

    Render what Flux would build for the `continuwuity` app:

    ```bash
    POSTBUILD_APP=continuwuity POSTBUILD_KOPIUR_CAPACITY=8Gi POSTBUILD_NAMESPACE=matrix \
      kustomize build kubernetes/apps/matrix/continuwuity/app \
        | grep -E 'kind: (KopiurBackup|Restore|SnapshotPolicy|SnapshotSchedule|PersistentVolumeClaim)' | sort
    ```

    Expected: a single `KopiurBackup` `KopiurBackup` instance named `continuwuity` (no raw `Restore`/`SnapshotPolicy`/etc. at this stage — those come from KRO expansion).

- [ ] **Step 5: Commit**

    ```bash
    git add kubernetes/components/kopiur/kustomization.yaml \
            kubernetes/components/kopiur/local/kustomization.yaml \
            kubernetes/components/kopiur/remote/kustomization.yaml
    git commit -m "feat(kopiur): render KopiurBackup instance from components"
    ```

---

## Task 5 — Pilot rollout on `continuwuity`

**Files:** none (cluster reconcile only)

**Interfaces:**

- Consumes: Flux-side reconcile of `kubernetes/apps/matrix/continuwuity/`

- [ ] **Step 1: Capture before-state**

    ```bash
    kubectl -n matrix get kopiur.restore,pvc,SnapshotPolicy,SnapshotSchedule -o yaml > /tmp/kopiur-before.yaml
    ```

    Note: under the previous layout, `continuwuity` had 1 Restore + 1 local SnapshotPolicy + 1 local SnapshotSchedule + 1 PVC.

- [ ] **Step 2: Let Flux reconcile**

    Wait for the relevant Flux `Kustomization` (the matrix namespace's per-namespace one) to pick up the new Component. Confirm:

    ```bash
    kubectl -n matrix get kustomization -o name | grep continuwuity
    flux get kustomizations --all-namespaces | grep continuwuity
    ```

    Expected: the per-namespace Flux Kustomization reports `Ready=True`.

- [ ] **Step 3: Verify rendered resources match the spec**

    ```bash
    kubectl -n matrix get kopiurbackup -o yaml
    kubectl -n matrix get restore,snapshotpolicy,snapshotschedule,pvc -o yaml > /tmp/kopiur-after.yaml
    diff -u /tmp/kopiur-before.yaml /tmp/kopiur-after.yaml
    ```

    Expected: semantic equivalence (PVC name `continuwuity`, capacity `8Gi`, retention `keepDaily:7 keepHourly:24`, cron `H * * * *`, `fromPolicy.name: continuwuity`, mover secctx `runAsUser: 1000`). Diff should be limited to the absence of raw kopiur CRs and the presence of a `KopiurBackup` instance CR.

- [ ] **Step 4: Verify cron actually triggers**

    Wait one full hour for the `H *` schedule to fire at least once. Confirm a `VolumeSnapshot` CR is created:

    ```bash
    kubectl -n matrix get volumesnapshot
    ```

    Expected: at least one snapshot exists.

- [ ] **Step 5: Commit (no code; log decision in `git log`)**

    ```bash
    git commit --allow-empty -m "chore(kopiur): pilot continuwuity rolled out, semantic diff clean"
    ```

---

## Task 6 — Roll out to all 29 apps

**Files:** none

- [ ] **Step 1: Force Flux reconcile on all app namespaces**

    ```bash
    flux reconcile kustomization --all-namespaces --with-source
    ```

- [ ] **Step 2: Sanity-check each namespace**

    ```bash
    kubectl get kopiurbackup -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,SCOPE:.spec.scope,CAPACITY:.spec.capacity
    ```

    Expected: 29 rows (one `KopiurBackup` per consumer namespace, including `kopiur-system`'s own potentially — verify it's _only_ the consumer apps).

- [ ] **Step 3: Spot-check three edge cases**
    - `paperless` (uses `KOPIUR_PVC: paperless-media`, `KOPIUR_STORAGECLASS: zfs-vault`):

        ```bash
        kubectl -n default get kopiurbackup paperless -o jsonpath='{.spec.pvcName}/{.spec.storageClass}'
        ```

        Expected: `paperless-media/zfs-vault`.

    - `hermes` (custom UID/GID, no `NAMESPACE` postBuild):

        ```bash
        kubectl -n hermes get kopiurbackup hermes -o jsonpath='{.spec.puid}/{.spec.pgid}'
        kubectl -n hermes get restore hermes -o jsonpath='{.spec.mover.securityContext.runAsUser}/{.spec.mover.securityContext.runAsGroup}'
        ```

        Expected: `10000/10000` in both, and `hermes` namespace confirmed for the instance.

    - `continuwuity` (the pilot, `local` only):

        ```bash
        kubectl -n matrix get snapshotpolicy continuwuity continuwuity-b2 -o name
        ```

        Expected: only `snapshotpolicy.kopiur.home-operations.com/continuwuity` exists; `-b2` policy must NOT exist.

- [ ] **Step 4: Commit (decision log)**

    ```bash
    git commit --allow-empty -m "chore(kopiur): all 29 consumer apps rolled out, edge cases verified"
    ```

---

## Task 7 — Delete the obsolete kustomize component tree

**Files:**

- Delete: `kubernetes/components/kopiur/base/` (entire subtree)
- Delete: `kubernetes/components/kopiur/remote/restore.yaml`
- Delete: `kubernetes/apps/kopiur-system/kopiur/config/resourcegraphdefinition.yaml` (untracked)

- [ ] **Step 1: Confirm no consumer references `components/kopiur/base*`**

    ```bash
    grep -rn 'components/kopiur/base' kubernetes/
    ```

    Expected: zero matches. If any survive, abort and migrate them first.

- [ ] **Step 2: Delete the files**

    ```bash
    git rm -r kubernetes/components/kopiur/base
    git rm    kubernetes/components/kopiur/remote/restore.yaml
    rm        kubernetes/apps/kopiur-system/kopiur/config/resourcegraphdefinition.yaml
    ```

- [ ] **Step 3: Validate Flux hasn't stashed any state references**

    ```bash
    flux suspend kustomization --all-namespaces 2>/dev/null || true
    kustomize build kubernetes/apps/kopiur-system/kopiur/config | kubeconform -summary
    flux resume  kustomization --all-namespaces 2>/dev/null || true
    ```

    Expected: kubeconform reports 0 errors.

- [ ] **Step 4: Final reconcile**

    ```bash
    flux reconcile kustomization --all-namespaces --with-source
    sleep 60
    flux get kustomizations --all-namespaces | grep -v True | head
    ```

    Expected: all 29 app Kustomizations `Ready=True`.

- [ ] **Step 5: Commit**

    ```bash
    git add -A
    git commit -m "chore(kopiur): remove obsolete kustomize component tree"
    ```

---

## Self-review

**1. Spec coverage**

- §4 RGD shape → Task 2
- §5 file delta → Tasks 2, 3, 4, 7
- §6 migration compatibility/edge cases → Task 5 (`int()` coercion observed in pilot), Task 6 (edge cases verified)
- §7 validation → Task 1 (pre-flight), Task 5 (pilot), Task 6 (full rollout)
- §8 open items A–H → Task 1 (Steps 1–3); E/F already in spec as finalised; G/H under "validation" Steps 2–4

**2. Placeholder scan**

- No `TODO`/`TBD`/etc. in the plan.
- All commands are concrete. File contents included verbatim.

**3. Type consistency**

- RGD instance template uses `scope`, `pvcName`, `capacity`, `storageClass`, `accessModes`, `snapshotClass`, `puid`, `pgid` — identical to the RGD schema in Task 2.
- The kustomize substitution chain `${KOPIUR_PUID:=${PUID:=1000}}` is preserved verbatim from today's behaviour to keep per-app Flux `postBuild.substitute` working without changes.
- `${int(...)}` is used consistently for `puid`/`pgid` everywhere they appear in the RGD template.
