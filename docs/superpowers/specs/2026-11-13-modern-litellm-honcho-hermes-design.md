# Modern LiteLLM routing for Honcho and Hermes

## Intent

Replace the legacy LiteLLM model inventory and direct AgentGateway model paths
with modern provider routes. Honcho and Hermes must both use the private
LiteLLM proxy for every model request, including Honcho embeddings.

## Goals

- Keep only current provider families in LiteLLM model definitions.
- Route all Honcho generation and embedding requests through LiteLLM.
- Route Hermes generation through LiteLLM's OpenAI-compatible `/v1` endpoint.
- Use 1536-dimensional Honcho embeddings; the live pgvector columns must be
  confirmed compatible before rollout.
- Keep raw Kubernetes resources out of `resources/` directories. Those
  directories remain for Kustomize generator inputs and Kustomize config files.
- Preserve the existing Mealie LiteLLM integration while replacing its legacy
  model alias.

## Non-goals

- Changing unrelated direct Ollama, AgentGateway, OpenClaw, or Open WebUI
  integrations that do not use LiteLLM.
- Adding provider failover. Each alias has one explicit upstream so model
  selection remains predictable.
- Changing Hermes memory semantics; Hermes continues to use Honcho memory.

## Constraints

- Allowed text providers/models are the supplied modern families:
  `chatgpt/gpt-6.1-*`, `minimax/MiniMax-M3*`, and
  Neuralwatt's `glm-5.3`/`glm-5.3-flash` models through its
  OpenAI-compatible API.
- Embeddings use Neuralwatt's `qwen3-embedding-8b` through its
  OpenAI-compatible API.
- Qwen3 Embedding 8B defaults to 4096 dimensions but supports requested
  dimensions. LiteLLM will request 1536 dimensions for Honcho. The model
  configuration must allow the `dimensions` parameter through the OpenAI
  adapter, and a rendered-config plus API smoke test must verify it is
  preserved.
- Hermes receives a dedicated LiteLLM virtual key. The operator-generated
  Secret is mirrored from `ai` to `hermes` using reflector annotations.

## Model and consumer map

| LiteLLM alias | Upstream | Consumer | Purpose |
| --- | --- | --- | --- |
| `honcho-fast` | `minimax/MiniMax-M3.1-Flash` | Honcho | Deriver and all dialectical levels |
| `honcho-quality` | `chatgpt/gpt-6.1-sol` | Honcho | Summary, dream deduction, and dream induction |
| `honcho-embedding` | Neuralwatt `qwen3-embedding-8b` via LiteLLM's `openai` adapter | Honcho | Memory embeddings, requested at 1536 dimensions |
| `hermes` | `minimax/MiniMax-M3` | Hermes | Primary agent generation through LiteLLM `/v1` |
| `mealie` | Neuralwatt `glm-5.3-flash` via LiteLLM's `openai` adapter | Mealie | Existing OpenAI-compatible Mealie integration |

The old Ollama, Groq, and ChatGPT 5.4 LiteLLM aliases are removed. Direct
Ollama consumers remain unchanged because they do not route through LiteLLM.

## Honcho reasoning effort

Honcho v3 supports `MODEL_CONFIG__THINKING_EFFORT` on each feature and on
each dialectic level. The implementation will set these independently rather
than applying one global value:

| Honcho workload | Alias | Effort |
| --- | --- | --- |
| Deriver | `honcho-fast` / MiniMax M3.1-Flash | `low` |
| Dialectic `minimal` | `honcho-fast` / MiniMax M3.1-Flash | `low` |
| Dialectic `low` | `honcho-fast` / MiniMax M3.1-Flash | `low` |
| Dialectic `medium` | `honcho-fast` / MiniMax M3.1-Flash | `medium` |
| Dialectic `high` | `honcho-fast` / MiniMax M3.1-Flash | `high` |
| Dialectic `max` | `honcho-fast` / MiniMax M3.1-Flash | `max` |
| Summary | `honcho-quality` / GPT-6.1 Sol | `medium` |
| Dream deduction | `honcho-quality` / GPT-6.1 Sol | `high` |
| Dream induction | `honcho-quality` / GPT-6.1 Sol | `high` |

MiniMax M3.1-Flash explicitly supports `low`, `medium`, `high`, `xhigh`, and
`max` reasoning effort. The GPT quality route uses Honcho's OpenAI-compatible
`medium`/`high` values. Hermes remains on MiniMax M3; its existing Hermes
agent-level reasoning setting is retained, but no Honcho-style LiteLLM model
effort override is configured.

## Approaches

1. **Role-based explicit aliases (selected).** One scoped alias per workload,
   with the provider chosen for that workload's latency or quality needs.
   This keeps routing auditable and prevents accidental provider changes.
2. **One shared provider.** Simpler, but loses the requested provider choice
   and creates a larger single-provider dependency.
3. **Multi-provider fallback aliases.** More resilient, but makes behavior,
   cost, and model semantics less predictable. Deferred unless failover is
   explicitly requested.

## Implementation design

- Move LiteLLM's raw `LiteLLMModel` and `LiteLLMVirtualKey` manifests from
  `kubernetes/apps/ai/litellm/app/resources/` to the app directory and list
  them directly from `kustomization.yaml`.
- Add `hermes` to the LiteLLM virtual-key resources, scoped to the `hermes`
  alias and annotated for reflector mirroring.
- Update LiteLLM's health checks to include the Hermes virtual key.
- Change Honcho's embedding model and endpoint to `honcho-embedding` through
  LiteLLM, setting `EMBEDDING_VECTOR_DIMENSIONS=1536`, automatic dimension
  handling, an 8192-token input limit, and a maximum batch size of 10.
- Before rollout, query the live Honcho pgvector column typmods and confirm
  they are 1536; changing a populated vector schema is a separate re-embedding
  migration and is not performed by these manifests.
- Keep Honcho's existing `honcho-fast`/`honcho-quality` role assignments but
  point their aliases at the new providers. Add the per-feature and
  per-dialect `THINKING_EFFORT` settings from the reasoning table above.
- Change Hermes config to `provider: custom`, model `hermes`, base URL
  `http://litellm.ai.svc.cluster.local/v1`, `api_mode: chat_completions`, and
  a key environment variable populated from the mirrored virtual-key Secret.
  Remove the direct AgentGateway custom provider and direct MiniMax credential.
- Make Hermes depend on the AI LiteLLM Kustomization in addition to Honcho.
- Replace Mealie's `llama3.1:8b` model selection with the `mealie` alias.
- Leave Hermes' `resources/config.yaml`, `resources/honcho.json`, and
  `resources/kustomizeconfig.yaml` in place because they are ConfigMapGenerator
  inputs or Kustomize configuration, not raw Kubernetes resources.

## Verification

- `kustomize build kubernetes/apps/ai/litellm/app` renders only modern model
  routes and both scoped virtual keys.
- `kustomize build kubernetes/apps/ai/honcho/app` shows every Honcho model
  endpoint at LiteLLM and no AgentGateway model endpoint.
- `kustomize build kubernetes/apps/hermes/hermes/app` shows the LiteLLM URL,
  chat-completions mode, and the mirrored-key reference.
- Rendered output contains no raw LiteLLM model/key manifests under a
  `resources/` directory.
- Validate the LiteLLM `/v1/models` and embeddings/chat-completions smoke
  paths after deployment; specifically confirm the embedding response has 1536
  values and both scoped keys can access only their declared aliases.
