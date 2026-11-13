# Honcho + Hermes Performance Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reactivate LiteLLM through `litellm-operator`, use ChatGPT OAuth through LiteLLM `v1.109.1`, route Honcho's text generation through it, tune Honcho for fresher/lower-latency memory, and switch Hermes to native Honcho memory without the Memini plugin.

**Architecture:** Install the LiteLLM operator and controller in `litellm-system`. Manage the one-replica LiteLLM proxy, model routes, virtual key, OAuth PVC, and Service in `ai`. Honcho in `ai` consumes the generated scoped key and routes hot-path models to LiteLLM; Hermes in `hermes` depends on Honcho and uses `HONCHO_BASE_URL` plus a minimal file-based peer identity.

**Tech Stack:** Kubernetes YAML, Kustomize, Flux v2, LiteLLM Operator CRDs (`litellm.home-operations.com/v1alpha1`), LiteLLM `v1.109.1`, Honcho v3 environment configuration, SOPS, External Secrets, Kopiur PVC backups, Cosign.

**Spec:** `docs/superpowers/specs/2026-11-12-honcho-hermes-performance-design.md`

## Global Constraints

- `litellm-operator` controller namespace: `litellm-system`.
- LiteLLM proxy, `LiteLLMModel` resources, `LiteLLMVirtualKey`, generated Secrets, PVC, and Service namespace: `ai`.
- Operator OCI chart baseline: `0.0.26`, verified against the published CRD schema before use.
- LiteLLM image: exactly `ghcr.io/berriai/litellm-database:v1.109.1`, pinned by digest and Cosign-verified.
- LiteLLM replicas: exactly one; no public HTTPRoute; preserve `litellm.ai.svc.cluster.local` compatibility.
- ChatGPT OAuth state: writable persistent `CHATGPT_TOKEN_DIR=/app/chatgpt_tokens`; device login occurs out of band; never commit OAuth tokens.
- Honcho: one API replica with `API_WORKERS=1`, one deriver replica with `DERIVER_WORKERS=2`, `DB_POOL_SIZE=4`, `DB_MAX_OVERFLOW=2`, and representation batch age `300` seconds.
- Honcho runtime configuration is environment-only; remove the mounted `config.toml`.
- Honcho hot path and deriver use `honcho-fast`; summary and dream specialist work use `honcho-quality`.
- Hermes uses native `memory.provider: honcho`; remove plugin download/init logic, Memini environment variables, and Hermes-only Memini Secret references.
- Keep the shared Memini application because OpenClaw still uses it.

## Review Focus

- **OAuth refresh race and recovery:** one durable volume and one proxy replica must prevent two writers from rotating the single-use refresh token; test by inspecting the rendered pod, volume, and rollout configuration in Task 2 and the runtime login procedure in Task 6.
- **Cross-namespace operator watch scope:** the controller in `litellm-system` must reconcile CRs in `ai`; validate chart values, CRD status, and Flux ordering in Tasks 1 and 6.
- **Model-route preservation:** reactivation must not silently drop the current Ollama/Groq aliases; compare the old ConfigMap inventory with the rendered `LiteLLMModel` set in Task 3.
- **Secret boundaries:** Honcho receives only the generated virtual key, while ChatGPT OAuth remains on the PVC and never appears in YAML or logs; inspect rendered manifests and run secret-reference checks in Tasks 2, 4, and 6.
- **Client wire compatibility:** existing clients use `litellm.ai.svc.cluster.local` without an explicit port; verify Service port 80 compatibility or update every caller atomically in Tasks 2 and 6.

## File Structure

| Action | Path | Responsibility |
| --- | --- | --- |
| Create | `kubernetes/apps/litellm-system/kustomization.yaml` | Discover the operator Flux Kustomization in the new system namespace |
| Create | `kubernetes/apps/litellm-system/litellm-operator/ks.yaml` | Reconcile the operator HelmRelease in `litellm-system` |
| Create | `kubernetes/apps/litellm-system/litellm-operator/app/kustomization.yaml` | Operator app resource list |
| Create | `kubernetes/apps/litellm-system/litellm-operator/app/helmrelease.yaml` | Operator OCIRepository and HelmRelease |
| Modify | `kubernetes/flux/cluster/resourceset.yaml` | Add `litellm-system` to discovered namespaces |
| Modify | `kubernetes/apps/ai/kustomization.yaml` | Reactivate the LiteLLM Flux Kustomization |
| Modify | `kubernetes/apps/ai/litellm/ks.yaml` | Add operator dependency, Kopiur PVC, and app substitutions |
| Modify | `kubernetes/apps/ai/litellm/app/kustomization.yaml` | Switch from HelmRelease/ConfigMap to operator resources |
| Create | `kubernetes/apps/ai/litellm/app/litellmproxy.yaml` | One private `LiteLLMProxy` with v1.109.1 and OAuth storage |
| Create | `kubernetes/apps/ai/litellm/app/resources/models.yaml` | Existing routes plus Honcho ChatGPT aliases as `LiteLLMModel` CRs |
| Create | `kubernetes/apps/ai/litellm/app/resources/honcho-key.yaml` | Honcho `LiteLLMVirtualKey` |
| Delete | `kubernetes/apps/ai/litellm/app/helmrelease.yaml` | Retire the standalone app-template proxy |
| Delete | `kubernetes/apps/ai/litellm/app/resources/config.yaml` | Retire the ConfigMap model list after migration |
| Delete | `kubernetes/apps/ai/litellm/app/resources/kustomizeconfig.yaml` | Retire HelmRelease-only name reference wiring |
| Modify | `kubernetes/apps/ai/honcho/ks.yaml` | Add LiteLLM dependency and PVC/database substitutions if needed |
| Modify | `kubernetes/apps/ai/honcho/app/kustomization.yaml` | Remove the Honcho config ConfigMap |
| Modify | `kubernetes/apps/ai/honcho/app/helmrelease.yaml` | Environment-only config, proxy key, workers, and resources |
| Delete | `kubernetes/apps/ai/honcho/app/resources/config.toml` | Replace file configuration with environment variables |
| Modify | `kubernetes/apps/hermes/hermes/ks.yaml` | Depend on `ai/honcho` |
| Modify | `kubernetes/apps/hermes/hermes/app/kustomization.yaml` | Add minimal native `honcho.json` to the generated ConfigMap |
| Modify | `kubernetes/apps/hermes/hermes/app/helmrelease.yaml` | Remove Memini plugin logic and set `HONCHO_BASE_URL` |
| Modify | `kubernetes/apps/hermes/hermes/app/resources/config.yaml` | Preserve native Honcho provider configuration |
| Create | `kubernetes/apps/hermes/hermes/app/resources/honcho.json` | Stable `hermes` workspace/peer identity |
| Modify | `kubernetes/apps/hermes/hermes/app/externalsecret.yaml` | Remove Memini secret references |

---

### Task 1: Install `litellm-operator` in `litellm-system`

**Files:**
- Create: `kubernetes/apps/litellm-system/kustomization.yaml`
- Create: `kubernetes/apps/litellm-system/litellm-operator/ks.yaml`
- Create: `kubernetes/apps/litellm-system/litellm-operator/app/kustomization.yaml`
- Create: `kubernetes/apps/litellm-system/litellm-operator/app/helmrelease.yaml`
- Modify: `kubernetes/flux/cluster/resourceset.yaml`

**Interfaces:**
- Produces: a ready `litellm-operator` Flux Kustomization and controller in `litellm-system`.
- Produces: the cluster-scoped LiteLLM CRDs used by the `ai` Kustomization.

- [ ] **Step 1: Verify the operator chart and CRD surface before writing manifests**

  Run:

  ```bash
  helm show chart oci://ghcr.io/home-operations/charts/litellm-operator --version 0.0.26
  helm show crds oci://ghcr.io/home-operations/charts/litellm-operator --version 0.0.26
  ```

  Confirm that the chart provides `LiteLLMProxy`, `LiteLLMModel`, and
  `LiteLLMVirtualKey` under `litellm.home-operations.com/v1alpha1`, supports
  cross-namespace reconciliation, and accepts the proxy volume, Service,
  image, replica, env, and virtual-key fields used by this plan. If the chart
  version or field names differ, update the plan values before continuing.

- [ ] **Step 2: Add the new namespace to Flux ResourceSet discovery**

  Add `litellm-system` to the namespace inputs in
  `kubernetes/flux/cluster/resourceset.yaml`. This causes the existing common
  component to create the namespace-scoped Flux Kustomization at
  `litellm-system-apps`.

- [ ] **Step 3: Create the operator app resources**

  Add the operator app Kustomization and Flux Kustomization. The app resource
  file must contain:

  - An `OCIRepository` named `litellm-operator` with URL
    `oci://ghcr.io/home-operations/charts/litellm-operator`, chart media type
    layer selection, and tag `0.0.26`.
  - A HelmRelease named `litellm-operator` in `litellm-system`, using that
    OCIRepository, with leader election enabled, `llmkube.autoRegister: true`,
    and the reference controller resource requests/limits.

  The Flux Kustomization must target `litellm-system`, health-check the
  operator HelmRelease in that namespace, wait for readiness, and use the
  repository's standard `flux-system` GitRepository source.

- [ ] **Step 4: Render the operator namespace path**

  Run:

  ```bash
  kustomize build kubernetes/apps/litellm-system
  ```

  Expected: the output contains the operator Flux Kustomization and no
  resources accidentally targeted at `ai`; the ResourceSet input contains
  `litellm-system` exactly once.

- [ ] **Step 5: Commit the operator installation**

  ```bash
  git add kubernetes/apps/litellm-system kubernetes/flux/cluster/resourceset.yaml
  git commit -m "feat: install litellm operator"
  ```

---

### Task 2: Replace the dormant standalone LiteLLM deployment with `LiteLLMProxy`

**Files:**
- Modify: `kubernetes/apps/ai/kustomization.yaml`
- Modify: `kubernetes/apps/ai/litellm/ks.yaml`
- Modify: `kubernetes/apps/ai/litellm/app/kustomization.yaml`
- Create: `kubernetes/apps/ai/litellm/app/litellmproxy.yaml`
- Delete: `kubernetes/apps/ai/litellm/app/helmrelease.yaml`

**Interfaces:**
- Consumes: the operator CRDs and `litellm-system/litellm-operator` readiness from Task 1.
- Consumes: the existing `components/database` and `components/kopiur` conventions.
- Produces: a one-replica `LiteLLMProxy` named `litellm` in `ai`.
- Produces: Service DNS `litellm.ai.svc.cluster.local` and durable PVC `litellm`.

- [ ] **Step 1: Reactivate the LiteLLM Flux Kustomization**

  Uncomment `./litellm/ks.yaml` in `kubernetes/apps/ai/kustomization.yaml`.
  In `kubernetes/apps/ai/litellm/ks.yaml`:

  - Add `../../../../components/kopiur` while retaining the database
    component. Remove `components/gatus/guarded` because the target proxy has
    no HTTPRoute for Gatus to probe.
  - Add `dependsOn` entries for `name: litellm-operator`, `namespace:
    litellm-system`, and `name: kopiur`, `namespace: kopiur-system`.
  - Set the Kopiur capacity to `1Gi`, with `ReadWriteOnce` and the repository's
    default `zfs-spark`/`csi-zfs` storage conventions.
  - Keep `targetNamespace: ai` and the existing SOPS/post-build conventions.

- [ ] **Step 2: Remove the standalone proxy wiring**

  Make the app Kustomization retain `secret.sops.yaml` but replace the
  HelmRelease/configMapGenerator entries with:

  ```yaml
  resources:
    - ./litellmproxy.yaml
    - ./secret.sops.yaml
  ```

  Leave the old ConfigMap source files unreferenced until Task 3 has captured
  the model inventory; do not delete them in this task.

- [ ] **Step 3: Define the operator-managed proxy**

  Create `litellmproxy.yaml` with `apiVersion:
  litellm.home-operations.com/v1alpha1`, `kind: LiteLLMProxy`, and name
  `litellm`. Set:

  - `applyMode: file`.
  - Image `ghcr.io/berriai/litellm-database:v1.109.1` with the verified digest
    from the release/reference pattern.
  - `replicas: 1`.
  - ClusterIP Service with the existing client-compatible port 80 targeting
    container port 4000. If the verified CRD rejects port 80, use a separate
    compatibility Service and document/update all callers atomically.
  - No route/HTTPRoute.
  - `CHATGPT_TOKEN_DIR=/app/chatgpt_tokens`.
  - `DATABASE_URL` from Secret `litellm-postgres`, key `url`, and the existing
    Dragonfly host/port environment values.
  - The database component's PostgreSQL client CSI volume mounted at
    `/var/run/secrets/postgresql` and `root-ca` ConfigMap mounted at
    `/var/run/secrets/root-ca`, because the old database component patch only
    mounted those volumes into HelmRelease pods.
  - `envFrom` Secret `litellm` so the existing master/Groq credentials remain
    available.
  - `apiAccess.masterKeyRef` pointing to Secret `litellm`, key
    `LITELLM_MASTER_KEY`.
  - EmptyDir mounts for `/app/cache`, `/tmp`, and any required runtime cache
    paths, plus PVC `litellm` mounted at `/app/chatgpt_tokens`.
  - Existing production logging, timeout, retry, Redis cache, and database
    settings represented using the operator's `routerSettings`,
    `litellmSettings`, and `generalSettings` fields.
  - Resource requests/limits sufficient for one proxy, starting at the
    existing 1Gi memory ceiling unless operator validation shows a required
    change.

- [ ] **Step 4: Render and inspect the proxy resources**

  Run:

  ```bash
  kustomize build kubernetes/apps/ai/litellm/app > /tmp/litellm-rendered.yaml
  grep -E 'kind: (LiteLLMProxy|KopiurBackup|Secret)' /tmp/litellm-rendered.yaml
  grep -E 'v1\.109\.1|CHATGPT_TOKEN_DIR|litellm-postgres|litellm-key-honcho' /tmp/litellm-rendered.yaml
  ```

  Expected: all proxy resources are namespace-less inputs for the `ai` Flux
  Kustomization, the proxy has one replica, the OAuth PVC is mounted, and no
  old app-template HelmRelease or ConfigMap model list remains.

- [ ] **Step 5: Commit the proxy migration**

  ```bash
  git add kubernetes/apps/ai/kustomization.yaml kubernetes/apps/ai/litellm
  git commit -m "feat: manage litellm proxy with operator"
  ```

---

### Task 3: Migrate model routes and create Honcho's virtual key

**Files:**
- Create: `kubernetes/apps/ai/litellm/app/resources/models.yaml`
- Create: `kubernetes/apps/ai/litellm/app/resources/honcho-key.yaml`
- Modify: `kubernetes/apps/ai/litellm/app/kustomization.yaml`
- Delete: `kubernetes/apps/ai/litellm/app/resources/config.yaml`
- Delete: `kubernetes/apps/ai/litellm/app/resources/kustomizeconfig.yaml`

**Interfaces:**
- Consumes: `LiteLLMProxy` named `litellm` from Task 2.
- Produces: current Ollama/Groq aliases as `LiteLLMModel` resources.
- Produces: `honcho-fast` and `honcho-quality` aliases and Secret
  `litellm-key-honcho` with key `api-key`.

- [ ] **Step 1: Inventory the legacy model list**

  Record every non-commented model from the deleted ConfigMap before editing:
  `nomic-embed-text`, `all-minilm:22m`, `mxbai-embed-large`, `gemma3:4b`,
  `llava-llama3:8b` (including its two configured upstreams if duplicate
  routing is intentional), `gpt-oss:20b`, `gpt-oss:120b`,
  `llama4-scout:17b-16e`, `llama4-maverick:17b-128e`, `llama3.3:70b`, and
  `llama3.1:8b`. Preserve their provider, base URL, API-key environment, and
  embedding/completion mode.

- [ ] **Step 2: Resolve the authenticated ChatGPT model IDs without committing credentials**

  Complete the one-time OAuth login outside the proxy worker using the
  operator's mounted `CHATGPT_TOKEN_DIR`, then query the private proxy's
  authenticated `/v1/models` endpoint. Select and record:

  - the fastest plan-available model for `honcho-fast`;
  - the stronger plan-available model for `honcho-quality`.

  If no stronger model is exposed, map both aliases to the verified fast model.
  Do not place `auth.json`, access tokens, or refresh tokens in the repository.

- [ ] **Step 3: Write `LiteLLMModel` resources**

  Add one CR per legacy route and two ChatGPT alias CRs. Each must reference
  `proxyRef: litellm`. ChatGPT alias resources must use:

  ```yaml
  spec:
    modelName: honcho-fast # or honcho-quality
    proxyRef: litellm
    params:
      model: chatgpt/<verified-account-model-id>
    info:
      mode: responses
  ```

  Include the operator-supported metadata needed by Honcho (input/output token
  limits, function calling, prompt caching, and any required dropped params)
  without inventing fields not present in the verified CRD schema.

  Add `./resources/models.yaml` and `./resources/honcho-key.yaml` to the app
  Kustomization, then delete the now-unreferenced legacy ConfigMap source and
  its Helm name-reference configuration.

- [ ] **Step 4: Create the operator-managed virtual key**

  Create `LiteLLMVirtualKey` named `honcho` with `proxyRef: litellm`, key alias
  `Honcho`, Secret name `litellm-key-honcho`, and Secret key `api-key`. Apply
  the verified `models` allow-list field so the key is limited to
  `honcho-fast` and `honcho-quality`.

- [ ] **Step 5: Validate the migrated model set**

  Compare the rendered `LiteLLMModel` names and upstream parameters against
  the Task 1 inventory. Run the pinned CRD schema validation and ensure no
  plaintext key value is present in the output.

- [ ] **Step 6: Commit the model/key resources**

  ```bash
  git add kubernetes/apps/ai/litellm/app/resources kubernetes/apps/ai/litellm/app/kustomization.yaml
  git commit -m "feat: add operator-managed litellm models and honcho key"
  ```

---

### Task 4: Move Honcho configuration to env vars and route model calls through LiteLLM

**Files:**
- Modify: `kubernetes/apps/ai/honcho/ks.yaml`
- Modify: `kubernetes/apps/ai/honcho/app/kustomization.yaml`
- Modify: `kubernetes/apps/ai/honcho/app/helmrelease.yaml`
- Delete: `kubernetes/apps/ai/honcho/app/resources/config.toml`

**Interfaces:**
- Consumes: `litellm-key-honcho` Secret and `litellm.ai.svc.cluster.local` from Tasks 2–3.
- Produces: Honcho API and deriver pods with identical env configuration and separate worker commands.

- [ ] **Step 1: Add the Flux dependency on LiteLLM**

  Add `dependsOn` to `kubernetes/apps/ai/honcho/ks.yaml` for
  `name: litellm`, `namespace: ai`. Keep the existing database, Dragonfly, and
  secret components.

- [ ] **Step 2: Remove the config.toml ConfigMap**

  Remove the Honcho `configMapGenerator`, its configuration reference, and
  `resources/config.toml` from the app Kustomization. Do not leave a stale
  `/app/config.toml` mount in the HelmRelease.

- [ ] **Step 3: Add the common environment configuration**

  In the API/deriver container environment, preserve the current config values
  through their canonical environment names. At minimum, include:

  - App: `LOG_LEVEL=INFO`, `PERFORMANCE_LOG_FORMAT=compact`,
    `SESSION_OBSERVERS_LIMIT=10`, `GET_CONTEXT_MAX_TOKENS=100000`,
    `MAX_FILE_SIZE=5242880`, `MAX_MESSAGE_SIZE=25000`,
    `EMBED_MESSAGES=true`, `NAMESPACE=honcho`.
  - Database: current `DB_CONNECTION_URI` Secret reference plus
    `DB_SCHEMA=public`, `DB_POOL_CLASS=default`, `DB_POOL_PRE_PING=true`,
    `DB_POOL_SIZE=4`, `DB_MAX_OVERFLOW=2`, `DB_POOL_TIMEOUT=5`,
    `DB_POOL_RECYCLE=300`, `DB_POOL_USE_LIFO=true`, `DB_SQL_DEBUG=false`,
    `DB_TRACING=false`, `DB_CONNECT_TIMEOUT_SECONDS=2`.
  - Cache: `CACHE_ENABLED=true`,
    `CACHE_URL=redis://localhost:6379/0?suppress=true`,
    `CACHE_DEFAULT_TTL_SECONDS=300`, `CACHE_DEFAULT_LOCK_TTL_SECONDS=5`.
  - Embedding: preserve the existing `bge-m3` model, 1024 dimensions,
    `agentgateway-proxy` base URL, and `AG_API_KEY` environment reference.
  - Vector store: `VECTOR_STORE_TYPE=pgvector`,
    `VECTOR_STORE_MIGRATED=false`, `VECTOR_STORE_NAMESPACE=honcho`.
  - LLM: preserve `LLM_DEFAULT_MAX_TOKENS=2500`, tool output/message caps,
    auth-disabled behavior, enabled peer cards, and disabled telemetry/metrics
    behavior from the existing file.

- [ ] **Step 4: Configure LiteLLM-backed model paths**

  Inject `HONCHO_LITELLM_API_KEY` from Secret `litellm-key-honcho`, key
  `api-key`, into both containers. Set every text-generation module to the
  OpenAI transport with:

  ```text
  base_url = http://litellm.ai.svc.cluster.local/v1
  api_key_env = HONCHO_LITELLM_API_KEY
  ```

  Use `honcho-fast` for `DERIVER_MODEL_CONFIG__MODEL` and all five
  `DIALECTIC_LEVELS__<level>__MODEL_CONFIG__MODEL` values. Use
  `honcho-quality` for summary and both dream specialist models. Preserve all
  existing output-token, tool-iteration, summary, and dream limits unless the
  verified model schema requires a compatibility adjustment.

- [ ] **Step 5: Tune workers and freshness**

  Set `API_WORKERS=1`, `DERIVER_WORKERS=2`, preserve adaptive/jittered polling,
  and set `DERIVER_REPRESENTATION_BATCH_MAX_AGE_SECONDS=300`. Set API resources
  to requests `500m/1Gi`, limits `1 CPU/2Gi`; set deriver resources to requests
  `500m/1Gi`, limits `2 CPU/2Gi`.

- [ ] **Step 6: Render Honcho and check all env names**

  Run:

  ```bash
  kustomize build kubernetes/apps/ai/honcho/app > /tmp/honcho-rendered.yaml
  grep -E 'config.toml|HONCHO_LITELLM_API_KEY|DERIVER_WORKERS|DB_POOL_SIZE|REPRESENTATION_BATCH_MAX_AGE|honcho-fast|honcho-quality' /tmp/honcho-rendered.yaml
  ```

  Expected: no config.toml mount or file, both workloads have the key Secret
  reference, and no Honcho text-generation path points to MiniMax or
  agentgateway.

- [ ] **Step 7: Commit Honcho configuration**

  ```bash
  git add kubernetes/apps/ai/honcho
  git commit -m "feat: route honcho models through litellm"
  ```

---

### Task 5: Remove Hermes Memini integration and finish native Honcho setup

**Files:**
- Modify: `kubernetes/apps/hermes/hermes/ks.yaml`
- Modify: `kubernetes/apps/hermes/hermes/app/kustomization.yaml`
- Modify: `kubernetes/apps/hermes/hermes/app/helmrelease.yaml`
- Modify: `kubernetes/apps/hermes/hermes/app/resources/config.yaml`
- Create: `kubernetes/apps/hermes/hermes/app/resources/honcho.json`
- Modify: `kubernetes/apps/hermes/hermes/app/externalsecret.yaml`

**Interfaces:**
- Consumes: ready `ai/honcho` Flux Kustomization from Task 4.
- Produces: Hermes native Honcho configuration with no Memini plugin or Memini secret dependency.

- [ ] **Step 1: Add the Hermes dependency**

  Add `dependsOn` to `hermes/ks.yaml` for `name: honcho`, `namespace: ai`.

- [ ] **Step 2: Add the minimal native Honcho identity file**

  Create `resources/honcho.json`:

  ```json
  {
    "hosts": {
      "hermes": {
        "enabled": true,
        "aiPeer": "hermes",
        "peerName": "hermes",
        "workspace": "hermes"
      }
    }
  }
  ```

  Add it to the existing `hermes-config` ConfigMap generator and mount/copy it
  into `/opt/data/honcho.json` alongside `config.yaml`.

- [ ] **Step 3: Remove the Memini plugin path**

  Delete the init-container download, commit pin, network fetch, and fallback
  logic. Replace it with deterministic startup cleanup that preserves rollback
  data by moving any stale plugin directory outside Hermes' active plugin
  search path:

  ```sh
  if [ -e /opt/data/plugins/memini ]; then
    mkdir -p /opt/data/.disabled-plugins
    mv /opt/data/plugins/memini /opt/data/.disabled-plugins/memini
  fi
  ```

  Keep the existing config copy and ownership handling. Set
  `HONCHO_BASE_URL=http://honcho.ai.svc.cluster.local` in the Hermes app
  container, retain `HERMES_HOME=/opt/data`, and remove all `MEMINI_URL`,
  `MEMINI_NAMESPACE`, and `MEMINI_API_KEY` references.

- [ ] **Step 4: Remove the Hermes Memini Secret lookup**

  Remove `MEMINI_API_KEY` from the ExternalSecret template and remove the
  `/memini` data source. Keep unrelated Hermes and MiniMax credentials intact.

- [ ] **Step 5: Render and inspect Hermes**

  Run:

  ```bash
  kustomize build kubernetes/apps/hermes/hermes/app > /tmp/hermes-rendered.yaml
  ! grep -Eq 'memini-hermes|MEMINI_URL|MEMINI_NAMESPACE|MEMINI_API_KEY|plugins/memini' /tmp/hermes-rendered.yaml
  grep -E 'memory:|provider: honcho|HONCHO_BASE_URL|honcho.json' /tmp/hermes-rendered.yaml
  ```

  Expected: native Honcho provider, endpoint env, identity file, and no
  rendered Memini plugin/secret references.

- [ ] **Step 6: Commit the Hermes migration**

  ```bash
  git add kubernetes/apps/hermes/hermes
  git commit -m "feat: restore hermes native honcho memory"
  ```

---

### Task 6: Supply-chain, render, dependency, and runtime verification

**Files:**
- Modify only if verification exposes a concrete defect in the Task 1–5 files.

**Interfaces:**
- Consumes: all resources from Tasks 1–5.
- Produces: verified manifests and a documented rollout/login procedure.

- [ ] **Step 1: Verify the LiteLLM image digest and signature**

  Run the immutable-key verification from the LiteLLM `v1.109.1` release:

  ```bash
  cosign verify \
    --key https://raw.githubusercontent.com/BerriAI/litellm/e82a3c646908ba0a6ee0beddc4310d7a6cac4065/cosign.pub \
    ghcr.io/berriai/litellm-database:v1.109.1
  ```

  Confirm the rendered digest matches the verified image. If it differs from
  the reference digest, update the manifest to the registry-confirmed digest;
  never remove the digest pin.

- [ ] **Step 2: Validate all local Kustomize outputs**

  Run:

  ```bash
  kustomize build kubernetes/apps/litellm-system >/tmp/litellm-system.yaml
  kustomize build kubernetes/apps/ai/litellm/app >/tmp/litellm-app.yaml
  kustomize build kubernetes/apps/ai/honcho/app >/tmp/honcho-app.yaml
  kustomize build kubernetes/apps/hermes/hermes/app >/tmp/hermes-app.yaml
  kubeconform -strict -summary \
    /tmp/litellm-system.yaml /tmp/litellm-app.yaml \
    /tmp/honcho-app.yaml /tmp/hermes-app.yaml
  ```

  Use the repository's published CRD schemas or `-ignore-missing-schemas` only
  for CRDs not available locally; do not suppress ordinary YAML/schema errors.

- [ ] **Step 3: Validate namespace placement and Flux ordering**

  Inspect rendered Flux Kustomizations and confirm:

  - operator HelmRelease/controller: `litellm-system`;
  - proxy CRs and generated resources: `ai`;
  - `ai/litellm` depends on `litellm-system/litellm-operator`;
  - `ai/honcho` depends on `ai/litellm`;
  - `hermes/honcho` depends on `ai/honcho`.

  If a CRD status/health check is supported by the pinned operator, use it so
  dependency readiness means the proxy Service/key are usable, not merely that
  the CR was accepted.

- [ ] **Step 4: Run manifest safety checks**

  Confirm with targeted searches that:

  - no Hermes manifest contains `memini-hermes`, `MEMINI_URL`,
    `MEMINI_NAMESPACE`, `MEMINI_API_KEY`, or a plugin download;
  - no Honcho ConfigMap or `config.toml` mount remains;
  - no ChatGPT OAuth token or `auth.json` content is in Git;
  - no public LiteLLM route exists;
  - only one LiteLLM replica is rendered;
  - the current model aliases all have corresponding `LiteLLMModel` resources.

- [ ] **Step 5: Perform the controlled runtime bootstrap**

  After applying the operator and proxy resources:

  1. Confirm the `LiteLLMProxy` is Ready and the Service is reachable only
     inside the cluster.
  2. Perform device login once outside the proxy request worker, writing
     `auth.json` to the mounted `CHATGPT_TOKEN_DIR`.
  3. Query `/v1/models` and verify both aliases using the generated Honcho key.
  4. Confirm Honcho API readiness and run one dialectic request plus one
     deriver/representation job.
  5. Confirm Hermes starts with native Honcho memory and that the old
     `/opt/data/plugins/memini` directory is absent.

- [ ] **Step 6: Capture verification evidence and review the consequential change**

  Record each command, working directory, result, and limitation in the final
  change summary. Request one independent review focused on OAuth token
  persistence/rotation, cross-namespace operator authority, virtual-key
  exposure, destructive Memini cleanup, and Honcho concurrency/pool budgets.
