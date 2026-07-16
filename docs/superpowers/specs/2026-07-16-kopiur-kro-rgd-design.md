# Convert the `kopiur` kustomize Component and its specialisations into KRO ResourceGraphDefinitions

- **Date**: 2026-07-16
- **Status**: Approved
- **Owner**: m00n

## 1. Context

The home-lab Flux cluster ships a backup pattern around
[`kopiur`](https://github.com/home-operations/kopiur) (a kopia-based
volume-snapshot controller). Today this pattern is expressed as three
kustomize `Component` manifests under `kubernetes/components/kopiur/`:

| Component path                        | Effect                                                                                                                          |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `kubernetes/components/kopiur` (root) | PVC + local `Restore` + local `SnapshotPolicy` + local `SnapshotSchedule` + remote `SnapshotPolicy` + remote `SnapshotSchedule` |
| `kubernetes/components/kopiur/local`  | PVC + local `Restore` + local `SnapshotPolicy` + local `SnapshotSchedule`                                                       |
| `kubernetes/components/kopiur/remote` | PVC + remote `Restore` (sourcing the `${APP}-b2` policy) + remote `SnapshotPolicy` + remote `SnapshotSchedule`                  |

The kopiur `ClusterRepository`, `ExternalSecret`, `HTTPRoute`, and the
operator `HelmRelease` themselves live in
`kubernetes/apps/kopiur-system/kopiur/` — they are out of scope for this
design.

Twenty-nine consumer apps include one of the three Components in their
Flux `Kustomization.spec.components`, with per-app overrides supplied
via `postBuild.substitute` variables (`${KOPIUR_CAPACITY}`, `${KOPIUR_PVC}`,
`${KOPIUR_STORAGECLASS}`, `${KOPIUR_PUID}`, `${KOPIUR_PGID}`, …).

[KRO](https://kro.run/) was deployed today (`feat(kro): deploy`) and
offers `ResourceGraphDefinition` (RGD): a typed, CEL-driven way to
declare a multi-resource template whose instances expand into a graph
of Kubernetes resources on the cluster. One untracked sample RGD
(`resourcegraphdefinition.yaml`) currently lives in
`kubernetes/apps/kopiur-system/kopiur/config/`.

## 2. Goals

- Replace the three kustomize `Component`s under
  `kubernetes/components/kopiur/` with one KRO `ResourceGraphDefinition`
  named `KopiurBackup`.
- Each consumer app's `ks.yaml` stays untouched. The `Component` include
  paths still work; they now render a single `KopiurBackup` instance
  into the app namespace instead of multiple raw kopiur CRs.
- Keep per-app overrides (`KOPIUR_*` Flux `postBuild.substitute`
  variables) flowing through unchanged.
- Preserve every observable behaviour that consumers rely on today:
  PVC name, capacity, storage class, data source, retention, cron,
  compression, mover security context, and SnapshotPolicy/Schedule
  naming.
- Make the `local`/`remote`/`both` split first-class on the new API as
  a single `spec.scope: enum` field.

## 3. Non-goals

- Converting the kopiur operator `HelmRelease` itself.
- Converting `ClusterRepository`, `ExternalSecret`, or `HTTPRoute`
  (cluster-scoped config under `kubernetes/apps/kopiur-system/kopiur/config/`).
- Touching any of the 29 consumer `ks.yaml` files.
- Touching `${PUID}/${PGID}` defaults sourced from
  `substituteFrom: cluster-secrets` — those continue to flow through
  Flux and into the kustomize stage.
- Defining a `status:` block on the RGD schema (see §10).

## 4. The new RGD shape

The RGD defines a new namespaced API:
`kro.run/v1alpha1` kind `KopiurBackup` (the _RGD_ is a
`ResourceGraphDefinition`; the _CR it produces_ is `KopiurBackup`).

```kro
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
        metadata: { name: ${schema.metadata.name} }
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
      template: { ... SnapshotPolicy ... repo: garage, name: ${metadata.name} ... }
    - id: localSchedule
      includeWhen:
        - ${schema.spec.scope == "local" || schema.spec.scope == "both"}
      template: { ... SnapshotSchedule ... cron: "H * * * *" ... }
    - id: remotePolicy
      includeWhen:
        - ${schema.spec.scope == "remote" || schema.spec.scope == "both"}
      template: { ... SnapshotPolicy ... repo: b2, name: ${metadata.name + "-b2"} ... }
    - id: remoteSchedule
      includeWhen:
        - ${schema.spec.scope == "remote" || schema.spec.scope == "both"}
      template: { ... SnapshotSchedule ... cron: "H 0 * * *" ... }
```

Full file body, including the policy/schedule templates verbatim from
today's `base/{local,remote}/*.yaml`, lives in
`docs/superpowers/plans/2026-07-16-kopiur-kro-rgd.md` (Task 2, Step 1).

### Why a single RGD with `includeWhen` (not three RGDs)

- One CRD, one instance kind, one mental model.
- The local vs. remote `Restore` differs only by the
  `source.fromPolicy.name` ternary, so a single `restore` resource
  covers all three modes.
- Apps that include `components/kopiur` today continue to see
  identical behaviour under `scope: both` with the schema defaults.

## 5. File layout (delta)

### Created

- `kubernetes/apps/kopiur-system/kopiur/config/kopiurbackup-rgd.yaml`
  — the `ResourceGraphDefinition` definition (full body in the
  plan, Task 2 Step 1).
- `kubernetes/components/kopiur/instance.yaml`
  — single `KopiurBackup` instance template with `spec.scope: both`
  (default), `metadata.name: ${APP}`, no `metadata.namespace` (relies
  on kustomize auto-namespacing from the parent Flux Kustomization's
  `targetNamespace`).
- `kubernetes/components/kopiur/local/instance.yaml`
  — same template, `spec.scope: local`.
- `kubernetes/components/kopiur/remote/instance.yaml`
  — same template, `spec.scope: remote`.

### Modified

- `kubernetes/components/kopiur/kustomization.yaml` — replace
  `resources: [./base, ./base/local, ./base/remote]` with
  `resources: [./instance.yaml]`.
- `kubernetes/components/kopiur/local/kustomization.yaml` — replace
  `resources: [../base, ../base/local]` with
  `resources: [./instance.yaml]`.
- `kubernetes/components/kopiur/remote/kustomization.yaml` — replace
  `resources: [../base, ../base/remote, ./restore.yaml]` with
  `resources: [./instance.yaml]`.
- `kubernetes/apps/kopiur-system/kopiur/config/kustomization.yaml` —
  replace `./resourcegraphdefinition.yaml` (untracked sample)
  with `./kopiurbackup-rgd.yaml`.

### Deleted

- `kubernetes/components/kopiur/base/`
  (entire subtree: `base/kustomization.yaml`, `base/pvc.yaml`,
  `base/local/`, `base/remote/`).
- `kubernetes/components/kopiur/remote/restore.yaml`.
- `kubernetes/apps/kopiur-system/kopiur/config/resourcegraphdefinition.yaml`
  (untracked sample RGD).

### Untouched

- All 29 consumer app `ks.yaml` files (their `components:` include
  paths and `postBuild.substitute` overrides keep working untouched).
- `kubernetes/apps/kopiur-system/kopiur/{app,config}/*` other than the
  rgd swap.
- `kubernetes/flux/cluster/resourceset.yaml`.

### Namespacing strategy

Each per-app Flux `Kustomization` sets `spec.targetNamespace`. Kustomize
auto-applies that namespace to any rendered resource that doesn't set
its own `metadata.namespace`. Therefore the `instance.yaml` template
does _not_ set `metadata.namespace`, and `hermes` (the only consumer
without a `${NAMESPACE}` postBuild substitute) Just Works via the same
mechanism the original `base/pvc.yaml` relied upon.

## 6. Migration compatibility

### Behaviour preserved

- All PVCs (same name, capacity, storage class, dataSourceRef).
- Single `Restore` per app (same name, same mover secctx, same
  `fromPolicy` semantics — local under `local`/`both`, b2 under
  `remote`).
- `SnapshotPolicy`/`SnapshotSchedule` names (`${APP}` for local,
  `${APP}-b2` for remote).
- Cron, retention, compression, verification schedules — copied
  verbatim.

### Edge cases handled inline

- **`puid`/`pgid` type drift.** Flux `postBuild.substitute` produces
  strings (quoted or unquoted depending on source). The RGD schema
  declares `string | default="1000"`; the instance template uses
  `${int(schema.spec.puid)}` / `${int(schema.spec.pgid)}` at every
  destination to coerce before reaching the kopiur CR. This accepts
  both quoted (`"10000"`) and unquoted (`10000`) substitutes (verified
  in Task 1 against kro v0.9.2).
- **Single `Restore` across scopes.** Today's kustomize layout has
  local and remote Restores mutually exclusive at the include level
  (root component does _not_ include `remote/restore.yaml`). The
  RGD's single `restore` resource plus a CEL ternary on
  `fromPolicy.name` preserves this exactly.
- **`scope: remote` only fires `restore` once.** The single `restore`
  resource still produces one `Restore` CR per app (always); only its
  `fromPolicy.name` differs.

### Edge cases deferred (out of scope)

- Converting the cluster-scoped kopiur CRs (`ClusterRepository`,
  `ExternalSecret`, `HTTPRoute`) — see §3.
- A possible `kro.run/v1alpha1`-group alternative for the new API
  (currently we use the default `kro.run/v1alpha1` group).

## 7. Validation

1. **Static checks** — `kubeconform` against the RGD schema (and the
   kopiur CRD schemas) before commit.
2. **Cluster dry-run** — apply the RGD plus a synthetic `KopiurBackup`
   instance in a kind/k3d sandbox; confirm the expected number of
   `Restore`/`SnapshotPolicy`/`SnapshotSchedule`/`PVC` resources land
   per `scope` value.
3. **Reconcile diff observation** — pick one production app (e.g.
   `continuwuity`, the cleanest because it already uses `local`-only
   and has `KOPIUR_CAPACITY: 8Gi` as the only `KOPIUR_*` override).
   Apply the RGD in `kopiur-system`; let Flux reconcile; capture the
   resources rendered by the new Component vs. the old component
   side-by-side, confirm semantic equivalence (same names, same
   contents modulo the `metadata.namespace` propagation path).
4. **Roll-out order** — flip the three Components in place; let Flux
   reconcile all 29 apps; observe no PVC/Restore/Snapshot disruption
   (they are immutable once bound, but Flux `kustomize.toolkit.fluxcd.io/prune: disabled`
   annotation on the PVC keeps it safe).

## 8. Open items for the implementation plan

These don't change the design but block the implementation plan:

A. **RGD placement vs. Flux reconciliation.** Verify kro v0.9.2's
expected placement for `ResourceGraphDefinition` (cluster- vs.
namespace-scoped) and confirm `kopiur-config` Flux `Kustomization`
(which has no `targetNamespace`) picks it up correctly.
B. **Existing untracked `resourcegraphdefinition.yaml`** — addressed in
§5 (deleted in the same change set).
C. **`hermes` namespace** — addressed in §5 namespacing strategy
(no-op, kustomize auto-namespaces).
D. **`status:` block** — out of scope for v1 (§3, §10).
E. **Naming: `KopiurBackup`** (singular, PascalCase) — finalised.
F. **File naming: `instance.yaml`** (no underscore) — finalised.
G. **kustomize variable scoping.** Confirm that kustomize-style
`${KOPIUR_PUID:=${PUID:=1000}}` substitution chains degrade
gracefully — i.e. that the RGD sees a single concrete value once
kustomize has completed, and does not attempt to interpret the
`:=` operator. Expected: yes (kustomize substitutes before Flux
applies; kro only sees the resolved YAML).
H. **`int()` coercion test** — write a quick unit-style test that
confirms `${int("10000")}` returns `10000` and `${int("1000")}`
returns `1000` in CEL.

## 9. Roll-back plan

The change set is fully reversible:

- Re-create the deleted `base/` tree from git history.
- Restore the original `kustomization.yaml` files for the three
  Components.
- Revert `kubernetes/apps/kopiur-system/kopiur/config/kopiurbackup-rgd.yaml`
  (or just delete it, since KRO controller will garbage-collect any
  orphaned instances on its own).

## 10. Out-of-scope / future work

- `status:` block on the RGD schema (e.g. `pvcPhase`, `restoreReady`,
  `lastSnapshotTime`) for dashboarding.
- Converting `ClusterRepository`/`ExternalSecret`/`HTTPRoute` into
  RGDs.
- Converting the kopiur operator `HelmRelease` itself.
- A typed status aggregator that exposes a single
  `apps.kopiur/BackupStatus` view across apps.

## 11. Review checklist (self-review)

- [x] No `TODO`/`TBD` placeholders.
- [x] No internal contradictions: §4 resource count = §5 created
      files = §6 behaviour preserved.
- [x] Scope is single-plan-sized (one RGD + three Component edits +
      file moves).
- [x] Two-way ambiguous requirements resolved: - `scope` defaults to `both` (matches today's root component). - `puid`/`pgid` declared `string` in schema, coerced via
      `${int(...)}` because Flux substitutes strings (Task 1
      finding B; corrected in this revision). - enum syntax is `string | enum="local,remote,both"`, not
      `enum{local, remote, both}` (Task 1 finding A). - `Restore` is _always_ one (today has exactly one in each
      mode); only its `fromPolicy.name` differs by mode. - `metadata.namespace` not set in the instance template
      (kustomize auto-applies from the parent `targetNamespace`).
      (kustomize auto-applies from the parent `targetNamespace`).
