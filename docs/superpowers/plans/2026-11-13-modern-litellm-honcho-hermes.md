# Modern LiteLLM/Honcho/Hermes Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace legacy LiteLLM routes and direct Honcho/Hermes model paths with modern provider aliases, per-workload reasoning effort, and private LiteLLM routing.

**Architecture:** LiteLLM owns five explicit aliases: `honcho-fast`, `honcho-quality`, `honcho-embedding`, `hermes`, and `mealie`. Honcho uses the first three through its OpenAI transport; Hermes uses the `hermes` alias through LiteLLM `/v1/chat/completions`; Mealie keeps its existing integration through a dedicated scoped key. Cross-namespace LiteLLM keys use the operator's generated Secret plus reflector or `proxyNamespace` support.

**Tech Stack:** Kubernetes YAML, Kustomize, Flux v2, LiteLLM Operator CRDs, External Secrets, Kubernetes reflector, Honcho v3 environment configuration, Hermes Agent custom OpenAI-compatible provider.

**Spec:** `docs/superpowers/specs/2026-11-13-modern-litellm-honcho-hermes-design.md`

## Global Constraints

- Use only `chatgpt/gpt-6.1-*`, `minimax/MiniMax-M3*`, and `neuralwatt/glm-5.3`/`neuralwatt/glm-5.3-flash` for text routes.
- Use `neuralwatt/qwen3-embedding-8b` for Honcho embeddings, requesting 1024 dimensions.
- Route every Honcho generation and embedding request through `http://litellm.ai.svc.cluster.local/v1`.
- Route Hermes generation through LiteLLM `/v1` using `api_mode: chat_completions`.
- Keep raw Kubernetes resources out of `resources/` directories; leave only generator inputs and Kustomize configuration there.
- Do not add provider fallback routes.
- Preserve the existing Honcho vector dimension of 1024.

## Review Focus

- Provider credential wiring must reference Secrets and never render secret values; test the ExternalSecret key names and LiteLLM env references.
- Hermes must use the reflected scoped key and OpenAI chat-completions transport; test the generated HelmRelease and absence of the direct AgentGateway provider.
- Honcho's embedding endpoint must be LiteLLM and its reasoning settings must be attached to the correct feature/level; test every configured environment variable.
- LiteLLM must not retain old Ollama, Groq, or GPT-5.4 model aliases; test the rendered model inventory and modes.
- Kustomize path moves must preserve generator behavior and avoid accidentally treating generator inputs as raw resources; build every affected app.

---

### Task 1: Replace the LiteLLM model and key inventory

**Files:**
- Create: `kubernetes/apps/ai/litellm/app/models.yaml`
- Create: `kubernetes/apps/ai/litellm/app/virtualkeys.yaml`
- Create: `kubernetes/apps/ai/litellm/app/provider-keys.yaml`
- Modify: `kubernetes/apps/ai/litellm/app/kustomization.yaml`
- Modify: `kubernetes/apps/ai/litellm/app/litellmproxy.yaml`
- Modify: `kubernetes/apps/ai/litellm/ks.yaml`
- Delete: `kubernetes/apps/ai/litellm/app/resources/models.yaml`
- Delete: `kubernetes/apps/ai/litellm/app/resources/honcho-key.yaml`

**Interfaces:**
- Produces aliases `honcho-fast`, `honcho-quality`, `honcho-embedding`, `hermes`, and `mealie`.
- Produces generated keys `litellm-key-honcho` and `litellm-key-hermes` with the model scopes required by later tasks; Task 4 produces `mealie-litellm-key` in the `default` namespace.
- Produces `MINIMAX_API_KEY` and `NEURALWATT_API_KEY` in a Secret consumed by LiteLLM's `envFrom`/environment configuration.

- [ ] **Step 1: Write the modern `LiteLLMModel` resources**

  Define exactly these upstreams:
  - `honcho-fast` → `minimax/MiniMax-M3.1-Flash`, API key `os.environ/MINIMAX_API_KEY`, response-capable/function-calling metadata.
  - `honcho-quality` → `chatgpt/gpt-6.1-sol`, response-capable/function-calling metadata.
  - `honcho-embedding` → `neuralwatt/qwen3-embedding-8b`, API key `os.environ/NEURALWATT_API_KEY`, embedding mode, `dimensions: 1024`.
  - `hermes` → `minimax/MiniMax-M3`, API key `os.environ/MINIMAX_API_KEY`, chat-completion/function-calling metadata.
  - `mealie` → `neuralwatt/glm-5.3-flash`, API key `os.environ/NEURALWATT_API_KEY`, chat-completion metadata.

- [ ] **Step 2: Add provider credentials without embedding values in Git**

  Create an ExternalSecret named `litellm-provider-keys` from the existing Infisical provider paths (`/minimax` and `/neuralwatt`) and template only `MINIMAX_API_KEY` and `NEURALWATT_API_KEY`. Do not copy the values into a SOPS file or model manifests.

- [ ] **Step 3: Add scoped virtual keys**

  Keep the Honcho key limited to `honcho-fast`, `honcho-quality`, and `honcho-embedding`. Add a Hermes key limited to `hermes` with reflector annotations allowing only namespace `hermes`. Add a Mealie key in the `default` namespace that references proxy `litellm` in namespace `ai` via `proxyNamespace: ai` and is limited to `mealie`.

- [ ] **Step 4: Wire resources and proxy environment**

  List the new raw manifests directly from `app/kustomization.yaml`, remove the two old `resources/` entries, add provider key environment names to the proxy, and remove the obsolete `GROQ_API_KEY` extra-config environment entry. Add the Hermes virtual key to the LiteLLM Flux health checks.

- [ ] **Step 5: Render and verify the inventory**

  Run:
  ```bash
  kustomize build kubernetes/apps/ai/litellm/app > /tmp/litellm-app.yaml
  grep -E 'honcho-fast|honcho-quality|honcho-embedding|hermes|mealie|MiniMax-M3|gpt-6.1-sol|qwen3-embedding-8b|glm-5.3-flash' /tmp/litellm-app.yaml
  ! grep -E 'llama3|gpt-oss|llava|gemma3|nomic|all-minilm|mxbai|gpt-5.4|groq/' /tmp/litellm-app.yaml
  ```
  Expected: the five modern aliases are present, old aliases are absent, and no secret values appear in rendered output.

### Task 2: Route Honcho generation, embeddings, and reasoning effort through LiteLLM

**Files:**
- Modify: `kubernetes/apps/ai/honcho/app/helmrelease.yaml`

**Interfaces:**
- Consumes the `litellm-key-honcho` Secret and the aliases from Task 1.
- Produces Honcho environment configuration with OpenAI transport, LiteLLM base URL, and explicit reasoning effort.

- [ ] **Step 1: Change embedding configuration**

  Set `EMBEDDING_MODEL_CONFIG__TRANSPORT=openai`, model `honcho-embedding`, base URL `http://litellm.ai.svc.cluster.local/v1`, API key env `HONCHO_LITELLM_API_KEY`, and retain `EMBEDDING_VECTOR_DIMENSIONS=1024`.

- [ ] **Step 2: Set generation transport and aliases**

  Set OpenAI transport, LiteLLM base URL, and `HONCHO_LITELLM_API_KEY` for deriver, every dialectic level, summary, dream deduction, and dream induction. Keep deriver and all dialectic levels on `honcho-fast`; keep summary and both dream specialists on `honcho-quality`.

- [ ] **Step 3: Configure per-workload reasoning effort**

  Add these exact variables:
  ```text
  DERIVER_MODEL_CONFIG__THINKING_EFFORT=low
  DIALECTIC_LEVELS__minimal__MODEL_CONFIG__THINKING_EFFORT=low
  DIALECTIC_LEVELS__low__MODEL_CONFIG__THINKING_EFFORT=low
  DIALECTIC_LEVELS__medium__MODEL_CONFIG__THINKING_EFFORT=medium
  DIALECTIC_LEVELS__high__MODEL_CONFIG__THINKING_EFFORT=high
  DIALECTIC_LEVELS__max__MODEL_CONFIG__THINKING_EFFORT=max
  SUMMARY_MODEL_CONFIG__THINKING_EFFORT=medium
  DREAM_DEDUCTION_MODEL_CONFIG__THINKING_EFFORT=high
  DREAM_INDUCTION_MODEL_CONFIG__THINKING_EFFORT=high
  ```

- [ ] **Step 4: Render and assert every Honcho route**

  Run:
  ```bash
  kustomize build kubernetes/apps/ai/honcho/app > /tmp/honcho-app.yaml
  grep -c 'http://litellm.ai.svc.cluster.local/v1' /tmp/honcho-app.yaml
  grep -E 'honcho-fast|honcho-quality|honcho-embedding|THINKING_EFFORT|bge-m3|agentgateway' /tmp/honcho-app.yaml
  ```
  Expected: all generation and embedding blocks point to LiteLLM; the three aliases and nine effort values are present; `bge-m3` and AgentGateway do not appear in Honcho's rendered environment.

### Task 3: Route Hermes through LiteLLM and remove the direct provider

**Files:**
- Modify: `kubernetes/apps/hermes/hermes/ks.yaml`
- Modify: `kubernetes/apps/hermes/hermes/app/kustomization.yaml`
- Modify: `kubernetes/apps/hermes/hermes/app/helmrelease.yaml`
- Modify: `kubernetes/apps/hermes/hermes/app/resources/config.yaml`
- Delete: `kubernetes/apps/hermes/hermes/app/externalsecret.yaml`

**Interfaces:**
- Consumes the reflected `litellm-key-hermes` Secret and `hermes` alias from Task 1.
- Produces Hermes config with `provider: custom`, `base_url: http://litellm.ai.svc.cluster.local/v1`, `api_mode: chat_completions`, `key_env: HERMES_LITELLM_API_KEY`, and model `hermes`.

- [ ] **Step 1: Update Flux dependency and generated config wiring**

  Add `dependsOn: name: litellm, namespace: ai` to the Hermes Flux Kustomization. Remove the deleted ExternalSecret from the app Kustomization while retaining `resources/config.yaml`, `resources/honcho.json`, and `resources/kustomizeconfig.yaml` as ConfigMapGenerator/configuration inputs.

- [ ] **Step 2: Replace the Hermes model provider config**

  Change the default model to `hermes`, use the LiteLLM `/v1` URL and `chat_completions` mode, set `key_env: HERMES_LITELLM_API_KEY`, and remove the direct AgentGateway custom provider and stale MiniMax credential references.

- [ ] **Step 3: Inject the mirrored key**

  Add an explicit `HERMES_LITELLM_API_KEY` `secretKeyRef` to `litellm-key-hermes`/`api-key`. Remove the unused `envFrom` reference to the deleted Hermes ExternalSecret.

- [ ] **Step 4: Render and verify Hermes**

  Run:
  ```bash
  kustomize build kubernetes/apps/hermes/hermes > /tmp/hermes-app.yaml
  grep -E 'model: hermes|litellm.ai.svc.cluster.local/v1|chat_completions|HERMES_LITELLM_API_KEY|litellm-key-hermes' /tmp/hermes-app.yaml
  ! grep -E 'agentgateway-proxy|MiniMax-M3|MINIMAX_API_KEY|anthropic_messages' /tmp/hermes-app.yaml
  ```
  Expected: Hermes has only the LiteLLM custom endpoint and its generated key reference; generator inputs remain mounted correctly.

### Task 4: Update Mealie to the modern scoped LiteLLM alias

**Files:**
- Modify: `kubernetes/apps/default/mealie/ks.yaml`
- Modify: `kubernetes/apps/default/mealie/app/kustomization.yaml`
- Modify: `kubernetes/apps/default/mealie/app/helmrelease.yaml`
- Delete: `kubernetes/apps/default/mealie/app/secret.sops.yaml`
- Create: `kubernetes/apps/default/mealie/app/litellm-key.yaml`

**Interfaces:**
- Consumes the `mealie` alias and cross-namespace LiteLLM proxy from Task 1.
- Produces `OPENAI_MODEL=mealie`, `OPENAI_BASE_URL=http://litellm.ai.svc.cluster.local`, and a generated scoped API key in the default namespace.

- [ ] **Step 1: Replace the legacy Mealie model and credential**

  Set `OPENAI_MODEL: mealie`, add `OPENAI_API_KEY` from Secret `mealie-litellm-key`/`api-key`, remove the old app Secret from the Kustomization, and remove the old `envFrom` solely used for that secret.

- [ ] **Step 2: Declare the cross-namespace LiteLLM key**

  Add a `LiteLLMVirtualKey` named `mealie` in namespace `default` with `proxyRef: litellm`, `proxyNamespace: ai`, `secretName: mealie-litellm-key`, and model scope `[mealie]`. Make the Flux Kustomization depend on `ai/litellm`.

- [ ] **Step 3: Render and verify Mealie**

  Run:
  ```bash
  kustomize build kubernetes/apps/default/mealie > /tmp/mealie-app.yaml
  grep -E 'OPENAI_MODEL: mealie|litellm.ai.svc.cluster.local|mealie-litellm-key|kind: LiteLLMVirtualKey' /tmp/mealie-app.yaml
  ! grep -E 'llama3.1:8b|llama3.3|gpt-oss' /tmp/mealie-app.yaml
  ```

### Task 5: Full validation and diff review

**Files:**
- No new files.

- [ ] **Step 1: Build all affected Kustomizations**

  Run:
  ```bash
  for path in \
    kubernetes/apps/ai/litellm/app \
    kubernetes/apps/ai/honcho/app \
    kubernetes/apps/hermes/hermes/app \
    kubernetes/apps/default/mealie/app; do
    kustomize build "$path" >/dev/null
  done
  ```
  Expected: all four builds exit successfully.

- [ ] **Step 2: Check YAML and repository hygiene**

  Run `git diff --check` and inspect `git diff --stat` plus the complete diff. Confirm no plaintext credentials, no raw LiteLLM manifests remain under `resources/`, and no old model identifiers remain in the affected model-routing files.

- [ ] **Step 3: Validate provider and API assumptions**

  After deployment, query authenticated LiteLLM `/v1/models`, exercise chat completion for `honcho-fast`, `honcho-quality`, `hermes`, and `mealie`, and exercise embeddings for `honcho-embedding`. Confirm the embedding vector length is 1024, each scoped key rejects models outside its declared scope, and Honcho/Hermes logs show LiteLLM as their endpoint.

- [ ] **Step 4: Commit the completed migration**

  ```bash
  git add docs/superpowers/specs/2026-11-13-modern-litellm-honcho-hermes-design.md \
    docs/superpowers/plans/2026-11-13-modern-litellm-honcho-hermes.md \
    kubernetes/apps/ai/litellm \
    kubernetes/apps/ai/honcho \
    kubernetes/apps/hermes/hermes \
    kubernetes/apps/default/mealie
  git commit -m "feat: route honcho and hermes through modern litellm"
  ```
