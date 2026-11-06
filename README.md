# uncensored-local-agent

One command to get a **fully local, open-weight, uncensored coding agent** on macOS or Linux:
[llama.cpp](https://github.com/ggml-org/llama.cpp) serves abliterated (Heretic/ARA) Qwen models,
[llama-swap](https://github.com/mostlygeek/llama-swap) routes and hot-swaps them behind one
OpenAI-compatible endpoint, and [OpenCode](https://opencode.ai) drives them as an agent, with the
[superpowers](https://github.com/obra/superpowers) skills (brainstorm → spec → plan → subagents).

No cloud, no API keys, no telemetry from the stack, no refusals from the default models. Everything
installs into your home directory; nothing needs root.

> Русская версия: [README.ru.md](README.ru.md). Model research behind the choices:
> [docs/RESEARCH.ru.md](docs/RESEARCH.ru.md). Catalog and profiles: [docs/MODELS.md](docs/MODELS.md).

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/mark-ssd/uncensored-local-agent/v0.1.0/install.sh | bash
# then, in any project:
ula test          # checks chat, tool calls, embeddings and rerank on every installed model
ula agent         # OpenCode on the local models
```

Options (after `bash -s --` when piping, or directly with `./install.sh`):

| flag | effect |
|---|---|
| `--profile NAME` | hardware profile (default: auto-detected from OS, RAM and GPU) |
| `--all-models` | also download the stock (non-abliterated) variants |
| `--no-models` | install the tooling only; `ula pull` later |
| `--no-service` | don't register the launchd / systemd user service |
| `--no-superpowers` | don't add the superpowers plugin to OpenCode |

Environment overrides: `ULA_MODELS_DIR` (put models on another disk), `ULA_PORT` (default 8090),
`ULA_LLAMA_CPP_TAG`, `ULA_LLAMA_SWAP_VER`, `ULA_OPENCODE_VER`, `ULA_ACCEL=cpu|cuda|rocm|vulkan`.

## What you get

```
OpenCode (build agent → coder, plan/architect/reviewer → architect, superpowers skills)
        │  OpenAI-compatible, http://127.0.0.1:8090/v1
llama-swap  ── loads/unloads models on demand, keeps embed+rerank resident
        │
llama-server (llama.cpp, Metal / CUDA / ROCm / Vulkan / CPU build picked automatically)
        │
GGUF models in ~/.local/share/ula/models (sha256-pinned in catalog/models.tsv)
```

Stable model names, whatever the hardware profile:

| alias | role |
|---|---|
| `coder` | fast executor for the agent loop (uncensored) |
| `architect` | slower, stronger model for design, planning and review (uncensored) |
| `coder-stock`, `architect-stock` | the original, non-abliterated weights (with `--all-models`) |
| `embed`, `rerank` | Qwen3 embedding + reranker for code RAG (`/v1/embeddings`, `/v1/rerank`) |
| `<alias>:fast` | same model with thinking disabled (`enable_thinking: false`) |

Any OpenAI-compatible tool can use the endpoint too (Aider, Continue, Cline, your own harness):
base URL `http://127.0.0.1:8090/v1`, any API key, model `coder`.

## Hardware profiles

`ula profile` shows the detected profile and the list; `ula profile NAME && ula pull` switches.

| profile | machine | `coder` (uncensored) | `architect` (uncensored) | both resident |
|---|---|---|---|---|
| `mac-16gb` | Apple Silicon 16 GB (tight fallback) | gpt-oss-20b heretic-ara MXFP4, 32K | same process | – |
| **`mac-24gb`** ✅ | Apple Silicon 24 GB | Qwen3.6-35B-A3B Heretic i1-IQ3_S, 64K | Qwen3.8-27B heretic-ARA i1-IQ3_M, 32K | swap |
| `mac-36gb` | Apple Silicon 36–48 GB | Qwen3.6-35B-A3B Heretic Q4_K_M, 64K | Qwen3.8-27B heretic-ARA Q4_K_M, 64K | swap |
| `mac-64gb` | Apple Silicon 64–96 GB | Qwen3.6-35B-A3B Heretic Q5_K_M, 64K | Qwen3.8-27B heretic-ARA Q4_K_M, 64K | yes |
| `mac-128gb` | Apple Silicon 128 GB+ | Qwen3.6-35B-A3B Heretic Q5_K_M, 128K | gpt-oss-120b Derestricted, 128K | yes |
| `gpu-16gb` | NVIDIA 16 GB + ≥32 GB RAM | Qwen3.6-35B-A3B Heretic Q4_K_M (MoE offload), 64K | Qwen3.8-27B heretic-ARA IQ3_M, 32K | swap |
| `gpu-24gb` | NVIDIA 24 GB (3090/4090) | Qwen3.6-35B-A3B Heretic IQ4_XS, 128K | Qwen3.8-27B heretic-ARA Q4_K_M, 64K | swap |
| `gpu-32gb` | NVIDIA 32 GB (5090) | Qwen3.6-35B-A3B Heretic Q5_K_M, 128K | Qwen3.8-27B heretic-ARA Q6_K, 128K | swap |
| `gpu-48gb` | NVIDIA 48 GB | Qwen3.6-35B-A3B Heretic Q4_K_M, 128K | Qwen3.8-27B heretic-ARA Q4_K_M, 64K | yes |
| `gpu-96gb` | NVIDIA 96 GB (RTX PRO 6000) | Qwen3.6-35B-A3B Heretic Q8_0, 256K | Qwen3.8-27B heretic-ARA Q8_0, 128K | yes |
| `cpu-16gb` | CPU only, 16 GB | gpt-oss-20b heretic-ara MXFP4, 32K | same process | – |
| `cpu-32gb` | CPU only, 32 GB | Qwen3.6-35B-A3B Heretic Q4_K_M, 64K | same model | – |
| `cpu-64gb` | CPU only, 64 GB | Qwen3.6-35B-A3B Heretic Q6_K, 128K | gpt-oss-20b heretic-ara, 64K | yes |
| `unified-128gb` | Strix Halo / DGX Spark 128 GB | Qwen3.6-35B-A3B Heretic Q6_K, 128K | gpt-oss-120b Derestricted, 128K | yes |
| **`tiny`** ✅ | anything (CI, smoke tests) | Qwen3-0.6B | same process | – |

✅ = run end to end on real hardware (MacBook Pro M4 Pro 24 GB; Ubuntu 24.04 arm64 container). The
other profiles are computed from GGUF headers and memory budgets and were adversarially reviewed,
but not run yet: run `ula test` and open an issue with the result. Every profile also has
`coder-stock` / `architect-stock` (original weights) via `--all-models`. Details, provenance of
every uncensored build and how to add your own: [docs/MODELS.md](docs/MODELS.md).

Measured on the M4 Pro 24 GB (llama-bench, b12176): coder 827 tok/s prompt / 66 tok/s generation,
architect 123 / 12.8 tok/s. A real OpenCode task (write a module + pytest tests, run them) took 64 s.

On 24 GB Macs only one ~14 GB chat model fits in the Metal working set (~17.8 GiB), so calling the
architect unloads the coder (a swap costs ~10–20 s plus re-reading the prompt). Larger profiles keep
both resident.

## Daily use

```bash
ula agent                 # TUI in the current directory; Tab switches build/plan agents
ula agent run "fix the failing test in tests/test_api.py"   # one-shot, non-interactive
ula status                # profile, endpoint, loaded models, files
ula unload                # free the memory right now
ula logs                  # router log
ula bench coder           # llama-bench prompt/generation speed
ula doctor                # environment checks
```

In OpenCode: the `build` agent uses `coder`; `plan` and the `architect` agent use `architect`;
`@reviewer` is a read-only review subagent on `architect`. superpowers skills load through the
`skill` tool ("use the brainstorming skill").

## Uncensored: what it means here

* **Weights:** the default `coder`/`architect` are Heretic / ARA abliterations of Apache-2.0 Qwen
  models: the refusal direction is removed with low KL divergence, so capability loss is small
  (see the research doc for measurements). Political framing baked into Chinese base models is
  *not* removed by abliteration.
* **Harness:** `templates/opencode/instructions.md` tells the agent to answer directly without
  moralising. OpenCode may only use the local provider (`policies`), its free cloud models,
  model-catalog fetch, update checks, web search (Exa) and Claude Code skill import are off, and
  sessions can't be shared. Set `ULA_WEBSEARCH=1` to allow web search with a prompt.
* **Not verified:** nobody has independently benchmarked tool calling of abliterated models. Run
  `ula test` and your own tasks; `coder-stock` is there to compare.
* **Takedowns:** Hugging Face occasionally removes uncensored repos. Keep a copy of the GGUFs you
  rely on; `ula catalog verify` (also weekly in CI) tells you when a pinned file disappears.

## Security

The agent runs shell commands as your user with full network access (OpenCode's default policy
allows everything; this repo adds "ask" for `git push` and `sudo`, keeps `explore` and `reviewer`
read-only). Uncensored models will do what you ask, including destructive things. Use a VM,
container or dedicated user account for untrusted work.

* The router and every llama-server require a per-install API key (`~/.config/ula/api-key`,
  mode 0600); CORS is limited to the router's own origin and request capture is off, so web pages
  in your browser can't read prompts from `127.0.0.1`. Everything binds to `127.0.0.1`.
* A repository's own `opencode.jsonc` / `.opencode/` is ignored (it could re-route the provider or
  grant itself permissions). Opt in per run with `ULA_PROJECT_CONFIG=1 ula agent`.
* Every downloaded binary and model is checked against a sha256 pinned in this repo
  (`catalog/binaries.tsv`, `catalog/models.tsv`, `catalog/templates.tsv`); a mismatch stops the install.

## Uninstall

```bash
ula uninstall                       # service + CLI link
rm -rf ~/.local/share/ula ~/.config/ula     # binaries, models, router config
# OpenCode config: ~/.config/opencode (a backup of any previous config sits next to it)
```

## Pinned versions

llama.cpp `b12176`, llama-swap `v270`, OpenCode `2.2.5`, superpowers `v7.0.2` (commit `22f0b463`,
installed as a local plugin directory, no git needed), Qwen chat-template fix v22.5. Linux needs
glibc ≥ 2.38 for the arm64/CUDA/ROCm llama.cpp builds (Ubuntu 24.04+, Debian 13+), and `libgomp`.

## License

MIT for this repository. Models, llama.cpp, llama-swap, OpenCode and superpowers keep their own
licenses (all permissive at the pinned versions; check model cards before commercial use).
