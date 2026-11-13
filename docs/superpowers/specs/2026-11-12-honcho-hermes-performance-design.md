# Honcho + Hermes Performance Setup

## Intent

Switch Hermes back to the supported native Honcho memory provider, remove the
Hermes-specific Memini plugin path, and improve Honcho throughput and latency
without disrupting other Memini consumers in the cluster. Route Honcho's model
calls through a private LiteLLM `v1.109.1` proxy so they can use the ChatGPT
subscription's Codex quota through OAuth.

## Goals

- Hermes uses Honcho through its native `memory.provider: honcho` integration.
- Hermes gets a profile-local self-hosted `honcho.json` pointing at the
  in-cluster Honcho service.
- Remove the Memini plugin download/init logic, Memini runtime variables, and
  Hermes-only Memini secret references.
- Keep the shared Memini service because OpenClaw still depends on it.
- Give Honcho independent API and deriver capacity, bounded PostgreSQL pools,
  correctly enabled cache use, and resources suitable for the workload.
- Optimize primarily for lower latency and fresher memory, with reasonable
  throughput rather than minimum resource use.
- Keep Honcho runtime and performance configuration in Helm environment
  variables rather than a mounted `config.toml`.
- Use LiteLLM `v1.109.1` with the native `chatgpt/` provider, persistent OAuth
  state, and a private ClusterIP endpoint for Honcho, managed by
  `litellm-operator` CRDs.
- Use a fast ChatGPT model alias on the synchronous dialectic and freshness-
  sensitive deriver paths; reserve a stronger alias for background synthesis.
- Make Hermes reconcile after the Honcho Kustomization.

## Non-goals

- Do not remove or migrate the cluster-wide Memini deployment.
- Do not migrate existing Memini memories into Honcho.
- Do not enable Honcho authentication or expose new public routes in this
  change; the current in-cluster integration uses the existing unauthenticated
  Honcho service.
- Do not expose LiteLLM publicly or put the ChatGPT OAuth refresh token in a
  Git-tracked Kubernetes Secret.
- Do not change Hermes’ model, dashboard, OAuth, or messaging configuration.

## Anti-goals

- Do not retain a compatibility shim between Hermes and Honcho.
- Do not scale API workers and Kubernetes replicas simultaneously without a
  connection-budget calculation.
- Do not trade away persistence or correctness for lower latency.

## Constraints and current state

- Hermes runs in namespace `hermes`; Honcho runs in namespace `ai`.
- `litellm-operator` runs in the dedicated `litellm-system` namespace; the
  LiteLLM proxy and its managed resources run in namespace `ai`.
- Hermes currently installs `memini-hermes` into the persistent data volume and
  points `MEMINI_URL` at `memini.ai.svc.cluster.local`.
- Hermes already declares `memory.provider: honcho`, but lacks the native
  `honcho.json` configuration.
- Honcho uses the shared PostgreSQL transaction pooler and the Dragonfly
  component’s local tunnel, so `CACHE_URL=redis://localhost:6379/0` is
  intentional.
- Honcho supports environment-variable overrides for its complete config;
  Hermes supports `HONCHO_BASE_URL` for the endpoint, but workspace and peer
  identity remain file-based in the native provider.
- ChatGPT subscription authentication is performed by LiteLLM, not Honcho.
  LiteLLM's `CHATGPT_TOKEN_DIR` must contain a writable `auth.json`; device
  login is performed out of band because a request worker cannot safely run
  interactive OAuth.
- The repository's existing LiteLLM deployment is currently an
  `app-template` HelmRelease with a ConfigMap model list. The target pattern
  uses the `litellm.home-operations.com/v1alpha1` `LiteLLMProxy`, `LiteLLMModel`,
  and `LiteLLMVirtualKey` resources.
- The current `kubernetes/apps/ai/kustomization.yaml` comments out
  `./litellm/ks.yaml`, so the repository-owned LiteLLM instance is dormant;
  the migration must safely reactivate it rather than assume a live in-place
  Deployment. Its PostgreSQL/Dragonfly configuration and model list are still
  the compatibility baseline.
- OpenClaw still uses Memini, so the Memini application remains deployed.

## Approaches considered

1. **Native Honcho integration (chosen).** Configure Hermes’ supported Honcho
   provider and remove the custom Memini plugin. This is the smallest runtime
   surface and follows the upstream Hermes integration.
2. **Memini-compatible adapter aimed at Honcho.** Rejected: it preserves an
   unsupported plugin boundary and duplicates provider behavior.

3. **Direct Honcho-to-cloud API.** Rejected for this requirement: it needs
   provider API billing and keys, not ChatGPT subscription/Codex quota.

4. **Standalone LiteLLM HelmRelease.** Rejected for this repository: it works,
   but duplicates the controller's model/key reconciliation and diverges from
   the existing `home-ops` operating pattern.

5. **Custom Codex OAuth proxy.** Rejected: it would add a separate unofficial
   token-forwarding implementation and operational surface. LiteLLM already
   supports the required ChatGPT OAuth flow, OpenAI-compatible endpoints, and
   the operator pattern used by the reference repository.

6. **Operator-managed LiteLLM (chosen).** Install `litellm-operator` through
   Flux, then express the proxy, model aliases, and scoped client key as CRDs.
   This keeps the proxy lifecycle and generated credentials declarative while
   allowing the existing PostgreSQL/Dragonfly backing services to remain. The
   operator chart follows the reference `0.0.26` OCI pattern, subject to
   verifying the release and CRD schema during implementation.

For performance, use one Honcho API replica with one API worker and one deriver
replica with two deriver workers, a bounded `4 + 2` SQLAlchemy pool per process,
and increased CPU/memory requests. This keeps the maximum application pool
budget below the PostgreSQL pooler’s per-user limit while allowing API requests
and derivation work to proceed independently. Keep adaptive polling, jitter,
and the local Dragonfly cache enabled.

## Design

### Hermes

- Keep `memory.provider: honcho`.
- Add a minimal `/opt/data/honcho.json` containing the stable `hermes`
  workspace/AI peer identity; provide the endpoint through
  `HONCHO_BASE_URL=http://honcho.ai.svc.cluster.local`.
- Retain the existing config-copy init container, but remove all plugin fetch,
  pin, and fallback logic.
- Remove `MEMINI_URL`, `MEMINI_NAMESPACE`, `MEMINI_API_KEY`, and the Hermes
  ExternalSecret lookup for `/memini`.
- Leave `HERMES_HOME=/opt/data` so the native provider resolves the local file.

### Honcho

- Run one API replica with `API_WORKERS=1`.
- Run one deriver replica with `DERIVER_WORKERS=2`.
- Remove the Honcho `config.toml` ConfigMap and express the intentional
  application, database, cache, embedding, deriver, dialectic, summary, dream,
  and vector-store settings as container environment variables.
- Set `DB_POOL_SIZE=4` and `DB_MAX_OVERFLOW=2` for a bounded connection
  budget across the API pod and deriver pod.
- Set API resources to `500m/1Gi` requests and `1 CPU/2Gi` limits; set deriver
  resources to `500m/1Gi` requests and `2 CPU/2Gi` limits to avoid CPU and
  memory starvation during LLM and embedding work.
- Preserve the Dragonfly-backed local cache and adaptive/jittered deriver
  polling; reduce representation batch age from 1800 seconds to 300 seconds to
  improve freshness while retaining batching.
- Remove any pre-existing `/opt/data/plugins/memini` directory from the Hermes
  PVC during startup so the old plugin is actually removed, not merely unused.
- Add the Hermes Kustomization dependency on the Honcho Kustomization.

### LiteLLM

- Install `litellm-operator` as a Flux-managed dependency, following the
  `home-ops` pattern: an OCIRepository plus an operator HelmRelease, with
  `llmkube.autoRegister: true` and leader election enabled. Place the
  operator HelmRelease and controller workload in `litellm-system`.
- Place the `LiteLLMProxy`, all `LiteLLMModel` resources,
  `LiteLLMVirtualKey`, generated key Secret, OAuth PVC, and proxy Service in
  `ai`. Configure the operator's watch scope/registration so it reconciles
  these `ai` resources from its `litellm-system` controller.
- Re-enable the LiteLLM Flux Kustomization and make it depend on the
  operator Kustomization in `litellm-system`. Make Honcho depend on the ready
  LiteLLM Kustomization in `ai` so its generated virtual-key Secret and Service
  exist before Honcho starts.
- Replace the current standalone LiteLLM `app-template` HelmRelease and
  ConfigMap model list with one `LiteLLMProxy` named `litellm`, one or more
  `LiteLLMModel` resources, and a `LiteLLMVirtualKey` for Honcho. Preserve the
  existing PostgreSQL database, Dragonfly cache, and other model routes while
  migrating their current model definitions to CRDs.
- Set the `LiteLLMProxy` image to exactly
  `ghcr.io/berriai/litellm-database:v1.109.1` with a verified immutable digest
  (the reference pattern currently uses
  `sha256:932c54440654f8f8466a85887612d95dcfb04ae2fc01257844332f4bf3b96986`);
  verify the digest and published Cosign signature before rollout rather than
  trusting the external repository blindly.
- Keep one proxy replica. A single writable OAuth state file avoids refresh-
  token races because ChatGPT refresh tokens are single-use.
- Set `CHATGPT_TOKEN_DIR=/app/chatgpt_tokens` and mount it from a durable
  persistent volume, following the reference operator pattern. Use the
  repository's existing storage conventions for encryption, backup, and reclaim
  policy. Ensure the one-replica rollout does not create two OAuth writers.
- Seed and refresh `auth.json` through an operational login procedure, not an
  interactive container startup hook and not plaintext Git data.
- The operator supplies the dedicated ChatGPT account during the one-time
  device login; no account identifier or OAuth material is committed.
- Add two model aliases as `LiteLLMModel` resources, both with
  `spec.info.mode: responses`:
  - `honcho-fast` -> `chatgpt/<fastest model available to the account>` for
    dialectic and deriver work. Start with the account's verified small/fast
    Codex model, expected to be the `gpt-5.4-mini` class.
  - `honcho-quality` -> `chatgpt/<stronger model available to the account>`
    for summaries and dream deduction/induction. Verify the concrete model ID
    against the authenticated `/v1/models` response; fall back to
    `honcho-fast` if the subscription does not expose a stronger model.
- Keep the proxy reachable only through its in-cluster ClusterIP Service; do
  not create an HTTPRoute for it. Honcho uses a `LiteLLMVirtualKey`-generated
  scoped key, stored in the operator-managed Secret, rather than the ChatGPT
  OAuth token or the LiteLLM master key.
- Limit the virtual key to the two Honcho aliases and rotate it independently
  of the ChatGPT OAuth file. Use the existing LiteLLM PostgreSQL-backed key
  store and operator reconciliation rather than a hand-written API bootstrap.
- Preserve the existing service identity `litellm.ai.svc.cluster.local` and
  the current no-port client contract where possible. Prefer an operator
  Service port of `80` targeting LiteLLM's container port `4000`; if the CRD
  only supports a `4000` Service port, add a compatibility Service or update
  every in-cluster client in the same change and validate both paths.
- Migrate every currently non-commented model alias from the dormant ConfigMap
  into `LiteLLMModel` resources, including Ollama and Groq routes needed by
  existing clients. Do not silently discard a route during the CRD migration;
  exact duplicate aliases must be checked for intentional weighted routing.

### Honcho model routing

- Change every text-generation module from the existing MiniMax/agentgateway
  route to the OpenAI transport pointed at
  `http://litellm.ai.svc.cluster.local/v1`, with the scoped proxy key supplied
  through an environment variable.
- Point dialectic levels `minimal`, `low`, `medium`, `high`, and `max` at
  `honcho-fast` to minimize user-visible latency. Keep their existing output
  and tool-iteration limits unless validation shows a model-specific issue.
- Point the deriver at `honcho-fast` so representation freshness benefits from
  low inference latency and the 300-second batch age.
- Point summary and dream deduction/induction at `honcho-quality`; these remain
  asynchronous and can spend more inference time for better durable memory.
- Use the same LiteLLM base URL and scoped key for all these modules. Embedding
  remains on the existing local agentgateway route unless a separate embedding
  migration is explicitly requested.

### Implementation-time checks

- Verify the authenticated account's `/v1/models` output and commit the
  concrete model IDs selected for `honcho-fast` and `honcho-quality`; fail
  validation if no fast model is available rather than silently choosing an
  unknown model.
- Exercise both the Honcho OpenAI client request shape and LiteLLM's bridged
  `/v1/chat/completions`/`/v1/responses` behavior before rollout. Keep
  `model_info.mode: responses` only if the installed Honcho client and model
  route require it.
- Verify the namespace NetworkPolicy/egress path permits LiteLLM's HTTPS
  connection to the ChatGPT backend while restricting Honcho to the LiteLLM
  Service; a ClusterIP alone is not an egress policy.
- Confirm the PostgreSQL pooler's actual per-user limit and count the API and
  deriver worker pools before applying `DB_POOL_SIZE=4` and
  `DB_MAX_OVERFLOW=2`.
- Confirm the operator's installed CRD schema supports the selected image,
  service port, persistent volume mounts, one-replica rollout, model metadata,
  and virtual-key Secret generation. Pin the verified OCI chart version rather
  than copying an unverified reference tag.
- Render and inspect the Flux dependency chain as
  `litellm-system/litellm-operator -> ai/litellm -> ai/honcho ->
  hermes/honcho`, and verify the generated LiteLLM Service and Honcho Secret
  names before enabling Hermes.

## Acceptance checks

- Rendered manifests contain no Hermes Memini plugin download, `MEMINI_URL`,
  `MEMINI_NAMESPACE`, or `MEMINI_API_KEY` reference.
- Rendered Hermes data contains a minimal native `honcho.json` with the stable
  identity mapping, and Hermes has `HONCHO_BASE_URL` set.
- Honcho has no mounted `config.toml`; its intentional settings are present as
  environment variables.
- LiteLLM renders exactly one `v1.109.1` pod with a digest-pinned image, a
  persistent `CHATGPT_TOKEN_DIR`, the two ChatGPT `LiteLLMModel` aliases, a
  `LiteLLMVirtualKey` for Honcho, and no public route. The proxy is owned by
  the `LiteLLMProxy` CRD and the operator is installed as a Flux dependency.
- Honcho's text-generation settings route through the LiteLLM ClusterIP and
  contain no direct ChatGPT OAuth token or agentgateway MiniMax route.
- The authenticated LiteLLM model list confirms the concrete fast and quality
  model IDs before they are committed to the rendered configuration.
- Honcho renders separate API and deriver replica counts and the intended pool,
  worker, cache, and resource settings.
- Kustomize/Helm schema or render validation succeeds for the changed app
  manifests.
- Git diff is limited to the Hermes/Honcho manifests, the new design/config
  files, and any required dependency declaration.

## Settled implementation calls

- Performance priority: lower latency and fresher memory.
- Replica count: one API replica and one deriver replica.
- Representation batch age: 300 seconds.
- Resource values above are starting allocations; no production benchmark
  baseline was provided, so post-deploy metrics should be used to refine them.
- Existing Hermes Memini plugin files are deleted during the migration startup
  step.
- LiteLLM version: exact `v1.109.1`; image digest and authenticated account
  model IDs are implementation-time verification inputs, not guessed values.
- LiteLLM OAuth storage uses one durable writable volume and a single-writer
  rollout; the OAuth bootstrap is performed by the operator outside the pod's
  request workers.
- The old LiteLLM HelmRelease/ConfigMap path is removed only after all existing
  model routes are represented by operator resources and rendered service/key
  names remain compatible with current in-cluster clients. Because the current
  top-level AI Kustomization has LiteLLM disabled, reactivation and migration
  must be validated as a first deployment, not treated as a zero-downtime
  in-place replacement.
