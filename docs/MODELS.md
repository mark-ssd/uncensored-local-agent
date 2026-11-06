# Models: catalog, profiles and aliases

This page explains how `ula` decides which GGUF files to download and how they reach
llama-swap and OpenCode. It also covers how to add a model safely, how the uncensored
variants were picked, where their files come from, and the risks that come with them.

The numbers below are a snapshot from 2026-11-06. The research behind them, with sources,
is in [RESEARCH.ru.md](RESEARCH.ru.md) (in Russian). Treat every version and score as
something to re-check, not a constant.

## How the pieces fit

```
catalog/models.tsv     what files exist (repo, file, size, sha256, license, llama-server args)
catalog/templates.tsv  chat templates the args can reference as {tpl:NAME} (url, sha256)
catalog/binaries.tsv   sha256 of every binary ula installs
profiles/<name>.env    which models this hardware runs, under which alias, with which context
        |
        v  ula render (also run by setup, pull and profile)
~/.config/ula/llama-swap.yaml        one llama-server command per installed alias, plus groups
~/.config/opencode/opencode.jsonc    one OpenCode model per installed chat alias
~/.config/ula/api-key                per-install key shared by both files (created on first render)
```

Harness configs only ever name **aliases**. Swapping the file behind `coder` is a
catalog or profile change. OpenCode, agents and scripts that call `coder` keep working
without edits.

## `catalog/models.tsv`

One GGUF file per line, pipe-separated. Lines that start with `#` are comments. The
comments also record where each uncensored file comes from (see [Provenance](#provenance)).

| # | Column | Meaning |
|---|---|---|
| 1 | `id` | Catalog id that profiles reference. Convention: `family-size[-variant]-quant`, e.g. `qwen3.8-27b-heretic-ara-iq3m`. |
| 2 | `kind` | `chat`, `embed` or `rerank`. It decides the llama-swap group, whether `ULA_CHAT_ARGS` and the `:fast` alias apply, and which checks `ula test` runs. |
| 3 | `hf_repo` | Hugging Face repo, e.g. `unsloth/Qwen3.8-27B-GGUF`. |
| 4 | `file` | Exact file name in the repo. It is also the local file name in `ULA_MODELS_DIR`. |
| 5 | `bytes` | File size, from the `x-linked-size` resolve header. Used for the disk-space check before a download. |
| 6 | `sha256` | From the `x-linked-etag` resolve header. Every download is verified against it. |
| 7 | `license` | License of the weights, for reference (`apache-2.0`, `mit`, ...). |
| 8 | `args` | Model-specific `llama-server` flags: the sampling the model card recommends, the chat template, `--embedding --pooling last`, `--reranking --pooling rank`, and so on. May contain `{tpl:NAME}` (see [Chat templates](#chat-templates)). |

Files are fetched from `https://huggingface.co/<hf_repo>/resolve/main/<file>`. The
download resumes after interruptions and is checked against the pinned sha256 before it
is moved into place. If the repo re-uploads a file under the same name, the download
fails on the checksum instead of silently installing different weights. The error
message names `ULA_VERIFY=0` as an escape hatch. Prefer updating the row on purpose.

## Chat templates

Every Qwen3.6 and Qwen3.8 row (heretic and stock) ends with:

```
--chat-template-file {tpl:qwen-fixed} --reasoning-format deepseek
```

The official Qwen 3.5/3.6/3.8 templates raise `System message must be at the beginning`
when a system message appears in the middle of a conversation, and some agent harnesses
send those. This was measured on the MacBook M4 Pro 24 GB: with the stock template the
late-system-message request returned HTTP 500, and with the fixed template it passes.
`--reasoning-format deepseek` puts the thinking into `reasoning_content`, which is the
field the generated OpenCode config reads.

`qwen-fixed` is [froggeric/Qwen-Fixed-Chat-Templates](https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates)
v22.5 (Apache-2.0). `catalog/templates.tsv` pins it by commit (`855bffc4...` in the
resolve URL) and by sha256.

How `{tpl:NAME}` works:

- `catalog/templates.tsv` has one line per template: `name|url|sha256`. Names use
  `a-z`, `0-9` and `-`.
- `ula pull` scans the `args` of every model it was asked for, downloads each referenced
  template to `$ULA_HOME/templates/NAME.jinja` (by default
  `~/.local/share/ula/templates/`) and checks the sha256, like a model file. A name that
  is not in `templates.tsv` stops the pull with an error.
- `ula render` replaces `{tpl:NAME}` with the quoted local path in the llama-server
  command.

Rows without a placeholder use the template embedded in the GGUF. That covers the gpt-oss
rows (harmony format), whose template silently drops a system message that is not the
first one instead of raising an error, and the `tiny` model (Qwen3-0.6B).

## `profiles/<name>.env`

A profile is a sourced shell file. 15 profiles ship:

| Profile | Machine (`PROFILE_DESC`) | `coder` | `architect` | `ULA_SWAP_LLMS` |
|---|---|---|---|---|
| `mac-16gb` | Apple Silicon, 16 GB unified memory (fallback: gpt-oss-20b heretic, 32K context, tight) | gpt-oss-20b heretic-ara-v3 MXFP4, 12.1 GB, 32K, `--n-cpu-moe 8` | same process as `coder` | true |
| `mac-24gb` | Apple Silicon, 24 GB unified memory | Qwen3.6-35B-A3B heretic i1-IQ3_S, 15.6 GB, 64K | Qwen3.8-27B heretic-ara i1-IQ3_M, 12.8 GB, 32K, KV q8_0 | true |
| `mac-36gb` | Apple Silicon, 36-48 GB unified memory | Qwen3.6-35B-A3B heretic i1-Q4_K_M, 21.7 GB, 64K | Qwen3.8-27B heretic-ara i1-Q4_K_M, 16.8 GB, 64K, KV q8_0 | true |
| `mac-64gb` | Apple Silicon, 64-96 GB unified memory (coder + architect resident) | Qwen3.6-35B-A3B heretic i1-Q5_K_M, 25.3 GB, 64K | Qwen3.8-27B heretic-ara i1-Q4_K_M, 16.8 GB, 64K, KV q8_0 | false |
| `mac-128gb` | Apple Silicon, 128 GB+ unified memory (gpt-oss-120b architect + Qwen3.6 coder resident) | Qwen3.6-35B-A3B heretic i1-Q5_K_M, 25.3 GB, 128K | gpt-oss-120b Derestricted MXFP4, 63.4 GB, 128K, reasoning effort high | false |
| `gpu-16gb` | Single NVIDIA GPU, 16 GB VRAM (+ >= 32 GB RAM) | Qwen3.6-35B-A3B heretic i1-Q4_K_M, 21.7 GB, 64K, `--n-cpu-moe 20` | Qwen3.8-27B heretic-ara i1-IQ3_M, 12.8 GB, 32K, KV q8_0 | true |
| `gpu-24gb` | Single NVIDIA GPU, 24 GB VRAM (3090 / 4090) | Qwen3.6-35B-A3B heretic i1-IQ4_XS, 19.2 GB, 128K | Qwen3.8-27B heretic-ara i1-Q4_K_M, 16.8 GB, 64K, KV q8_0 | true |
| `gpu-32gb` | Single NVIDIA GPU, 32 GB VRAM (5090) | Qwen3.6-35B-A3B heretic i1-Q5_K_M, 25.3 GB, 128K | Qwen3.8-27B heretic-ara i1-Q6_K, 22.4 GB, 128K, KV q8_0 | true |
| `gpu-48gb` | NVIDIA GPU, 48 GB VRAM (A6000 / 6000 Ada / L40S / 2x24 GB) | Qwen3.6-35B-A3B heretic i1-Q4_K_M, 21.7 GB, 128K | Qwen3.8-27B heretic-ara i1-Q4_K_M, 16.8 GB, 64K, KV q8_0 | false |
| `gpu-96gb` | NVIDIA GPU, 96 GB VRAM (RTX PRO 6000) | Qwen3.6-35B-A3B heretic Q8_0, 36.9 GB, 256K | Qwen3.8-27B heretic-ara Q8_0, 29.0 GB, 128K | false |
| `cpu-16gb` | CPU only, ~16 GB RAM (tight; 32 GB recommended) | gpt-oss-20b heretic-ara-v3 MXFP4, 12.1 GB, 32K | same process as `coder` | true |
| `cpu-32gb` | CPU only, ~32 GB RAM | Qwen3.6-35B-A3B heretic i1-Q4_K_M, 21.7 GB, 64K | same process as `coder` | true |
| `cpu-64gb` | CPU only, ~64 GB RAM | Qwen3.6-35B-A3B heretic i1-Q6_K, 29.2 GB, 128K | gpt-oss-20b heretic-ara-v3 MXFP4, 12.1 GB, 64K | false |
| `unified-128gb` | Unified memory 128 GB (Strix Halo, DGX Spark) | Qwen3.6-35B-A3B heretic i1-Q6_K, 29.2 GB, 128K | gpt-oss-120b Derestricted MXFP4, 63.4 GB, 128K, reasoning effort high | false |
| `tiny` | Tiny smoke-test profile (Qwen3-0.6B), any machine | Qwen3-0.6B Q8_0, 0.6 GB, 8K | same process as `coder` | false |

Sizes are file sizes in GB (10^9 bytes). "Same process" means both aliases name the same
file, context and args, so they run as one llama-server (see
[llama-swap groups](#llama-swap-groups)). `ULA_SWAP_LLMS=true` means only one chat model
is loaded at a time; on the one-process profiles it still keeps an uncensored and a stock
model from loading together. Each profile's header comment has its memory budget. On
`mac-16gb` and `cpu-16gb` the default download is `coder architect` only, because
`embed` and `rerank` do not fit beside them.

**What has actually been run.** Only two profiles were run on hardware:

- `mac-24gb`, on a real MacBook Pro M4 Pro 24 GB. Metal gives the GPU at most about
  17.8 GiB there, so only one chat model fits at a time.
- `tiny`, in a Linux arm64 container and on a Mac. It is useless for real work and only
  proves the pipeline is wired, which makes it right for CI.

The other 13 profiles were computed from GGUF headers and memory budgets (weights,
KV cache per token, compute buffers, the platform's GPU limit) and then reviewed
adversarially. Nobody has run them yet. If you are on one of those tiers, run `ula test`
(and `ula bench` if you can) and report the result, together with your hardware and the
memory lines from `ula logs` (Metal `recommendedMaxWorkingSetSize`, compute buffer
sizes), in an issue at
[mark-ssd/uncensored-local-agent](https://github.com/mark-ssd/uncensored-local-agent/issues).
If a model fails to load, lower its `ctx` first; several profile comments say which
value to try.

### Auto-detection

`ula` picks a profile with `auto_profile` (in `lib/models.sh`) only when none is set. An
explicit `--profile NAME` or `ULA_PROFILE` always wins, and `ula setup` saves the choice
in `~/.config/ula/ula.env`. `ula profile` prints the current profile and what
auto-detection would pick. Memory is total system RAM in whole GiB, rounded down.

1. **Apple Silicon (macOS arm64)**, by RAM: 120+ GiB `mac-128gb`, 60+ `mac-64gb`,
   34+ `mac-36gb`, 22+ `mac-24gb`, 15+ `mac-16gb`, less `tiny`. An 18 GB M3 Pro gets
   `mac-16gb`; a 48 GB Mac gets `mac-36gb`; a 96 GB Mac gets `mac-64gb`.
2. **NVIDIA (CUDA detected)**, by the VRAM of the largest single GPU: 90+ GiB
   `gpu-96gb`, 44+ `gpu-48gb`, 30+ `gpu-32gb`, 22+ `gpu-24gb`, 14+ `gpu-16gb`. VRAM is
   not summed, so two 24 GB cards get `gpu-24gb`; pass `--profile gpu-48gb` for them.
   A card under 14 GiB, or one that reports no memory size (DGX Spark / GB10 reports
   `[N/A]`, read as 0), falls through to step 3.
3. **Everything else** (CPU only, Vulkan, ROCm, Intel Macs), by RAM: 110+ GiB with a GPU
   backend (anything but `cpu`) `unified-128gb`; otherwise 60+ `cpu-64gb`, 30+
   `cpu-32gb`, 15+ `cpu-16gb`, less `tiny`. A 128 GB machine with no GPU backend
   therefore gets `cpu-64gb`.

The accelerator comes from `detect_accel`: Metal on Apple Silicon, CUDA when
`nvidia-smi -L` works, ROCm on x64 when `rocminfo` or `/dev/kfd` exists, Vulkan when
`vulkaninfo` lists a GPU, otherwise CPU. `ULA_ACCEL` overrides it. A Strix Halo with a
large BIOS VRAM carve-out reports less MemTotal and can land on a `cpu-*` profile; set
`ULA_PROFILE=unified-128gb` there.

### Profile fields

| Field | Default | Meaning |
|---|---|---|
| `PROFILE_DESC` | empty | One-line description shown by `ula status` and `setup`. |
| `ULA_MODELS` | required | One entry per line: `alias=catalog_id@ctx[@extra llama-server args]`. `ctx` becomes `--ctx-size` and OpenCode's `limit.context`. If it is left out, 8192 is used. |
| `ULA_DEFAULT` | empty | Aliases downloaded by `ula setup` and `ula pull`. `ula pull --all` takes every alias. |
| `ULA_CODER` | `coder` | Alias used by OpenCode's `build`, `general` and `explore` agents and as the default model. |
| `ULA_ARCHITECT` | `architect` | Alias used by the `plan` agent and the `architect` and `reviewer` subagents. If it is not downloaded, those agents use `ULA_CODER`. |
| `ULA_SWAP_LLMS` | `true` | `true`: one chat model at a time, llama-swap unloads one to load another. `false`: coder and architect stay loaded together, and other chat aliases go to a separate exclusive group. |
| `ULA_GPU_ARGS` | empty | Added to every model, e.g. `-ngl 999`. An alias can override it with its own extra args, such as `-ngl 0` (Mac) or `-ngl 0 --device none` (NVIDIA) for embed and rerank on CPU. |
| `ULA_CHAT_ARGS` | `--cache-ram 4096` | Added to chat models only. Profiles set the host-RAM prompt cache between 0 (`mac-16gb`, `cpu-16gb`) and 8192 MiB (`gpu-96gb`). |
| `ULA_TTL` | `900` | Seconds before an idle chat model is unloaded. Embed and rerank never expire. |
| `ULA_MIN_DISK_GIB` | `5` | Free space that must remain after the planned downloads. |
| `ULA_SERVER_ENV` | empty | Space-separated `KEY=value` pairs passed as the environment of each `llama-server`. |

`load_profile` refuses a profile whose alias points to a catalog id that does not exist.

The flags for one model are assembled in this order, so later flags win: the shared
macro (`--host 127.0.0.1 --port ${PORT} --api-key <key> --jinja --flash-attn on
--parallel 1 --no-webui`), then `--model` and `--ctx-size`, then `ULA_GPU_ARGS`,
`ULA_CHAT_ARGS` (chat only), the catalog `args` (with `{tpl:NAME}` expanded) and the
alias's extra args.

Only models that are already downloaded are rendered. An alias whose file is missing
does not exist for llama-swap or OpenCode until you `ula pull` it.

## Stable aliases

| Alias | `mac-24gb` uses | Role |
|---|---|---|
| `coder` | Qwen3.6-35B-A3B, Heretic (llmfan46), mradermacher Native-MTP-Preserved i1-IQ3_S, 15.6 GB, ctx 65536 | Agent executor. A MoE with ~3B active parameters, so it processes prompts about 7x faster than the dense 27B (measured below). |
| `architect` | Qwen3.8-27B, heretic-ara (trohrbaugh), mradermacher i1-IQ3_M, 12.8 GB, ctx 32768, KV `q8_0` | Design, specs and review. It is slow: 12.8 tok/s generation, and minutes to prefill a cold 32K prompt. |
| `coder-stock` | Qwen3.6-35B-A3B, unsloth UD-IQ3_S, 13.7 GB | The unmodified base of `coder`, for A/B comparisons and as a fallback. |
| `architect-stock` | Qwen3.8-27B, unsloth UD-IQ4_XS, 14.3 GB | The unmodified base of `architect`. |
| `embed` | Qwen3-Embedding-0.6B Q8_0 (official Qwen GGUF), CPU | Embeddings for code RAG (`/v1/embeddings`). |
| `rerank` | Qwen3-Reranker-0.6B Q8_0 (`ggml-org` conversion), CPU | Reranking (`/v1/rerank`). Qwen publishes no official reranker GGUF. |

Every profile uses the same six alias names; the table in [profiles](#profilesnameenv)
shows what is behind `coder` and `architect` elsewhere.

Default download on `mac-24gb`: `coder architect embed rerank`, about 29.7 GB. The stock
variants come with `ula pull --all` or `ula pull coder-stock architect-stock`.

### Measured on `mac-24gb`

MacBook Pro M4 Pro, 24 GB. `llama-bench` from llama.cpp b12176 with flash attention,
which is what `ula bench [alias]` runs (`-fa 1 -p 512,4096 -n 128`). Tokens per second:

| Alias | Build | pp512 | pp4096 | tg128 |
|---|---|---|---|---|
| `coder` | Qwen3.6-35B-A3B heretic Native-MTP-Preserved i1-IQ3_S (14.53 GiB as loaded) | 782 | 827 | 66 |
| `architect` | Qwen3.8-27B heretic-ara i1-IQ3_M | 125 | 123 | 12.8 |

`pp` is prompt processing, `tg` is generation. At the architect's 4K rate, a cold 32K
prompt takes more than four minutes to prefill.

End to end, a real OpenCode task on `coder` (write a fizzbuzz module plus pytest tests,
run them, tests pass) took 64 s.

No other profile has measured numbers yet.

## llama-swap groups

`ula render` writes the routing as llama-swap groups (`routing.router.use: group`):

| Group | Members | Settings |
|---|---|---|
| `main` | `ULA_CODER` and `ULA_ARCHITECT`. When `ULA_SWAP_LLMS=true`, every other chat alias too. | `swap` follows `ULA_SWAP_LLMS`. `exclusive` is true only when an `extra` group exists. |
| `extra` | Every other chat alias (the `-stock` models and any alternatives). Only rendered when `ULA_SWAP_LLMS=false`. | `swap: true`, `exclusive: true`: one at a time, and loading one unloads the resident coder/architect pair (and loading the pair unloads it). |
| `rag` | `embed` and `rerank`. | `persistent: true`, `swap: false`: stays loaded next to whichever chat model runs, `ttl: 0`. |

Chat models use `ttl: ULA_TTL`. Groups only contain installed models.

**Shared processes.** Profile entries with the same catalog id, context and extra args
run as one llama-server process. The model is named after the first alias in
`ULA_MODELS`, and the other names become llama-swap `aliases` of it. On `tiny`,
`mac-16gb`, `cpu-16gb` and `cpu-32gb`, `coder` and `architect` are one process, so
switching between the plan and build agents keeps the KV and prompt cache instead of
reloading the model.

### `:fast`

Every chat alias, including the names that are aliases of a shared process, also answers
as `<alias>:fast`, for example `coder:fast`. llama-swap routes that name to the same
process and sets, through the `setParamsByID` filter in the generated YAML:

```yaml
chat_template_kwargs:
  enable_thinking: false
  reasoning_effort: "low"
```

Use it for short mechanical turns where reasoning tokens are wasted time. It does not
load a second copy of the model. On Qwen this turns thinking off. gpt-oss (harmony) has
no thinking-off switch, so there `:fast` only lowers reasoning effort to low.

`ula test` checks that `:fast` answers. It no longer requires an empty
`reasoning_content`: if the model still emits some reasoning, the check passes and says
so.

The generated OpenCode config lists only the base aliases. To pick `:fast` from OpenCode,
add a model entry with `"modelID": "coder:fast"` in a project `opencode.jsonc` and run
with `ULA_PROJECT_CONFIG=1`, since project config is ignored otherwise (see
[Security and integrity](#security-and-integrity)).

## Adding a model safely

1. **Check that it fits.** The file plus its KV cache for the context you want must stay
   under the GPU limit (about 17.8 GiB on a 24 GB Mac). KV costs per token in f16 range
   from 20 KiB (Qwen3.6-35B-A3B) and 64 KiB (Qwen3.8-27B) to 208 KiB (Nanbeige4.3-33B),
   and `-ctk q8_0 -ctv q8_0` halves them. Do not use a `q4_0` KV cache: it breaks tool
   calls. Below 4 bits, quality drops and tool-name hallucinations rise, so treat 3-bit as
   a compromise only for 24 GB.
2. **Check the license** on the model card and in the repo's `LICENSE` file. An
   uncensored derivative inherits the base model's license. Avoid licenses whose rights
   end if guardrails are bypassed (NVIDIA Open Model License, Oct 2025) and gated repos,
   because `ula catalog verify` and the default download do not authenticate.
3. **Check provenance.** The GGUF repo must have been created after the source repo's
   last commit that changed the weights. See [Provenance](#provenance) for how, and record
   the dates in a catalog comment.
4. **Resolve size and sha256 from the headers**, never from a web page:

   ```bash
   repo=unsloth/Qwen3.8-27B-GGUF; file=Qwen3.8-27B-UD-IQ4_XS.gguf
   curl -sIL --max-redirs 0 "https://huggingface.co/$repo/resolve/main/$file" \
     | tr -d '\r' | grep -i -e '^HTTP' -e '^x-linked-size' -e '^x-linked-etag'
   ```

   Expect a `302`. Use `x-linked-size` as `bytes` and `x-linked-etag`, without quotes,
   as `sha256`. The same values are in `https://huggingface.co/api/models/$repo/tree/main`
   as `lfs.size` and `lfs.oid`.
5. **Add the catalog row.** Put the sampling the model card recommends in `args`, and
   `--chat-template-file {tpl:qwen-fixed} --reasoning-format deepseek` for Qwen3.5/3.6/3.8
   models. Do not put context, GPU or cache flags there, because those belong to the
   profile.
6. **Point an alias at it** in the profile. Either replace the id behind an existing
   alias, or add a new alias such as `coder-next`, try it, and then swap. Keep the
   names `coder` and `architect`, since everything downstream references them.
7. **Verify and test:**

   ```bash
   ula catalog verify          # every row: ok, or FAIL with HTTP code, size and sha
   ula pull coder-next         # downloads, checks sha256, fetches templates, re-renders configs
   ula test coder-next         # chat, tool call, tool call after a late system message, :fast
   ```

   llama-swap runs with `--watch-config`, so it picks up the re-rendered YAML. If it does
   not, run `ula restart`.
8. **Run your own eval** before relying on the model. `ula test` only proves the
   template and parser work. Section 10 of the research report has a half-day protocol:
   30-50 tool-call scenarios from your own domain, 10-20 real tickets run three times each
   at temperature > 0, and a stock-vs-uncensored comparison under the same harness and
   quantization.

### Writing a profile

Copy the shipped profile closest to your machine to a new name, then adjust:

- `ULA_MODELS`: larger quants or contexts, for example Q6/Q8 and 128K on 64 GB.
- `ULA_SWAP_LLMS=false` if both chat models fit at once.
- `ULA_GPU_ARGS`: `-ngl 999` for full offload. For a big MoE on one GPU, add per-alias
  extra args such as `--n-cpu-moe N`.
- The header comment: write down the memory budget the way the shipped profiles do, and
  say whether it was run on real hardware.

Then run `ula profile <name>`, `ula pull` and `ula test`. Auto-detection only returns the
15 shipped names, so select a new profile with `--profile` or `ULA_PROFILE`. A profile
that has been run on the hardware it names is worth much more than a computed one; say
which it is.

## How the uncensored variants were chosen

Three methods produce the variants worth considering. All of them edit the weights to
remove the model's "refusal direction" instead of fine-tuning on new data.

- **Abliteration**: classic directional ablation. It is cheap, but quality ranges from
  fine to broken.
- **Heretic** (p-e-w/heretic, v2.0.0, AGPL-3.0 for the tool itself): an automated search
  that minimises refusals together with the KL divergence from the base model. Since v2,
  ARA (Arbitrary-Rank Ablation) is the default. MPOA directional ablation is still
  available.
- **Norm-preserving biprojected abliteration** (grimjim; the ArliAI "Derestricted"
  builds): keeps weight norms intact. In the one independent measurement (gpt-oss-120b on
  UGI), NatInt ended up slightly above the stock model.

Selection rules used for the catalog:

- **KL divergence from the base model ≤ ~0.2**, measured on harmless prompts. It is the
  best single signal that the model's general behaviour was left alone. The `coder` build
  (llmfan46 Qwen3.6 Heretic MPOA) reports KL 0.0015.
- **Independent refusal and intelligence numbers, not only the author's refusal count.**
  On UGI, the `coder` build goes from willingness W/10 2.2 to 10.0 while NatInt rises
  slightly (31.03 to 31.62). A low self-reported refusal count does not mean the model
  answers: trohrbaugh ARA reports 0/100 refusals, but a HarmBench judge counts 57.5%
  successful answers.
- **ARA, MPOA or norm-preserving methods only**, and every build is checked on its own.
  The same method can yield a broken build, as with a Mistral-Small-3.2 "heretic" build
  that scored NatInt 5.09.
- **A known source upload.** The GGUF must have been made from the weights whose KL and
  refusal numbers are quoted (next section).

### Provenance

Uncensored repos get withdrawn and re-uploaded, and a GGUF made before a re-upload
contains the old weights under the same name. So the catalog records, for each
uncensored file, which upload it was converted from.

- **`coder` (Qwen3.6-35B-A3B).** Source: llmfan46's Heretic build. Its card reports
  Heretic v1.3.0, MPOA, KL 0.0015, 10/100 refusals. The catalog uses
  `mradermacher/Qwen3.6-35B-A3B-uncensored-heretic-Native-MTP-Preserved-i1-GGUF` (GGUF
  made 2026-05-24, source weights 2026-05-08); `mac-24gb` uses its i1-IQ3_S file,
  15.6 GB. These files keep the MTP layer (`blk.40`, 0.3-0.65 GiB), but llama.cpp b12176
  skips it at load unless MTP speculation / `--load-mtp` is on, so it only costs disk.
  `gpu-96gb` uses llmfan46's own Q8_0 GGUF.

  **Excluded:** the older mradermacher `Qwen3.6-35B-A3B-uncensored-heretic` GGUFs (static
  and i1, without `Native-MTP-Preserved` in the name). Comparing their tensor bytes with
  the current llmfan46 upload showed they were built from a withdrawn llmfan46 v1 upload
  whose KL is unknown. This is also why `mac-16gb` runs gpt-oss-20b: the verified
  Qwen3.6 files are too large for it.
- **`architect` (Qwen3.8-27B).** Source: `trohrbaugh/Qwen3.8-27B-heretic-ara` (ARA; card:
  KL 0.0535, 0/100 refusals). It has a single upload, and mradermacher converted it after
  that upload (i1 quants, and the static Q8_0 used by `gpu-96gb`). The independent
  measurement in the table below puts its KL at 0.059.
- **gpt-oss-20b heretic** (`mac-16gb`, `cpu-16gb`, `cpu-64gb`). Source: p-e-w
  `gpt-oss-20b-heretic-ara-v3` (KL 0.0554, 3/100 refusals), weights uploaded
  2026-03-05 08:45Z. `mradermacher/gpt-oss-20b-heretic-ara-v3-GGUF` quantized it on
  2026-03-06, after the upload.
- **gpt-oss-120b Derestricted** (`mac-128gb`, `unified-128gb`). Source: ArliAI
  Derestricted (norm-preserving biprojected ablation; UGI W/10 9.2, NatInt 35.70 against
  33.68 for stock). Weights uploaded 2025-11-28 14:46Z; the only later commit changed
  `chat_template.jinja` (2025-11-29 02:25). mradermacher converted it 2025-11-29 08:32Z.
  The catalog file, `gghfez/gpt-oss-120b-Derestricted.MXFP4_MOE-gguf` (uploaded
  2025-11-30), is the concatenation of mradermacher's MXFP4_MOE `part1of2` and `part2of2`:
  the sizes sum exactly and sampled byte ranges match. Its embedded chat template equals
  ArliAI's current `chat_template.jinja` byte for byte. gghfez is a personal account, so
  keep a local copy. That repo has no license tag; the GGUF's `general.license` and the
  ArliAI base are apache-2.0.
- **Stock models** come from unsloth, ggml-org (gpt-oss, the reranker) and Qwen (the
  embedding model and `tiny`).

**Rule for contributors:** before adding an uncensored GGUF, compare the GGUF repo's
`createdAt` with the date of the source repo's last commit that changed weight files. The
GGUF must be newer. If it is older, it was made from an earlier upload, and the card's
KL and refusal numbers do not describe it.

```bash
gguf=mradermacher/gpt-oss-20b-heretic-ara-v3-GGUF; src=p-e-w/gpt-oss-20b-heretic-ara-v3
curl -s "https://huggingface.co/api/models/$gguf" | grep -o '"createdAt":"[^"]*"'
curl -s "https://huggingface.co/api/models/$src/commits/main"   # dates and titles of every commit
```

A commit title does not always say which files changed; open the commit on the website
when in doubt. Write the dates into a catalog comment, as the existing rows do.

### The measured capability tax

These are independent measurements of Qwen3.8-27B variants (Abliterlitics: lm-eval on
vLLM, HarmBench with a judge). "Unfinished thinking" counts responses out of 400 harmful
prompts that never closed `<think>`.

| Variant | Judge ASR | Unfinished thinking /400 | HumanEval | IFEval | MMLU-Pro | KL |
|---|---|---|---|---|---|---|
| base | 4.5% | 1 | 79.3 | 82.07 | 62.82 | - |
| orcarouter | **82.2%** | 152 | 78.7 | 82.44 | 62.78 | 0.068 |
| apostate | 78.7% | 119 | 79.9 | 82.99 | 62.81 | 0.044 |
| huihui | 75.6% | 174 | 78.7 | 81.89 | 62.67 | 0.053 |
| rvn (0bserverx) | 71.3% | 104 | 81.7 | - | - | 0.084 |
| **trohrbaugh ARA** (catalog `architect`) | 57.5% | 61 | **82.3** | 82.26 | 62.65 | 0.059 |
| obliteratus | 63.9% | 179 | **45.7** | 77.63 | 56.49 | **1.54** (broken) |

What this means in practice:

- For good builds, the tax on general capability is within noise: HumanEval, IFEval and
  MMLU-Pro stay within about ±1 point. IFEval is the closest proxy here for format and
  JSON discipline.
- The real tax is **thinking loops on edgy prompts**. Answer-everything builds never close
  their reasoning far more often (152/400 for orcarouter against 1/400 for base). On
  ordinary tasks such as GSM8K, empty answers stay at 0-0.2% for every variant.
  `architect` uses the ARA build because it loops least (61/400) and has the best
  HumanEval, at the cost of a lower answer rate than orcarouter. orcarouter's repo is
  also gated.
- A KL of 1.54 shows up as a collapsed model (HumanEval 45.7), so the KL rule earns its
  place.
- Countermeasures for loops: a token cap per turn, non-greedy sampling (the catalog
  `args` use the model card's sampling), `presence_penalty`, and a thinking budget.

What abliteration does **not** do:

- It does not fix soft political framing in Chinese base models. That comes from
  training data and needs SFT. For geopolitical research, use Mistral or Gemma bases.
- It does not restore knowledge removed from training. Kimi K3.1 Pro, for example, had
  cyber-offence data removed.
- It does not make tool calls more reliable. The `-stock` aliases exist so you can tell
  whether a failure comes from the edit or from the base model.

## Security and integrity

**Pinned binaries, fail closed.** Every binary `ula` installs has a pinned sha256 in
`catalog/binaries.tsv`: the llama.cpp release archives (and the CUDA runtime archives),
llama-swap, OpenCode, and the superpowers tarball. If an asset has no pin, for example
after someone bumps `ULA_LLAMA_CPP_TAG`, `ULA_LLAMA_SWAP_VER` or `ULA_OPENCODE_VER`
without adding hashes, the install stops instead of installing unverified files. A hash
mismatch also stops it. `ULA_VERIFY=0` overrides both; don't use it casually. Archives
are extracted into a staging directory and renamed into place, so a failed install
leaves no half-installed directory.

**API key on the router and on every server.** The first render creates a per-install
key in `~/.config/ula/api-key` (24 random bytes, hex, file mode 0600). llama-swap
requires it (`apiKeys`), and every llama-server is started with the same `--api-key`,
so the backend ports (from 18100 up) do not answer without it either. The generated
`llama-swap.yaml` and `opencode.jsonc` contain the key and are written with mode 0600.
Without a key, any web page open in a browser on this machine could reach `127.0.0.1`
and read prompts. Clients outside OpenCode send it as `Authorization: Bearer <key>`.

**Browser and logging.** llama-swap's CORS only allows its own origin
(`http://127.0.0.1:8090` by default), and request captures are off (`captureBuffer: 0`),
so prompts and responses are not kept in memory for the web UI. llama-server runs with
`--no-webui`.

**OpenCode stays local.**

- The generated config has `policies` that deny every provider except `ula`, and deny
  the Exa web search integration.
- The `websearch` permission is `deny`. `ULA_WEBSEARCH=1` changes it to `ask`.
- Project-level config (`opencode.jsonc` or `.opencode/` in a repo) is ignored, because
  a cloned repo could use it to change providers and permissions. `ULA_PROJECT_CONFIG=1`
  turns it back on.
- Sharing and auto-update are off, and the free-model list and model fetching are
  disabled. The environment switches behind these are set both in the agent's
  environment and in the OpenCode background service.
- `git push` and `sudo` always ask.

**superpowers** is installed as a local plugin directory under
`~/.local/share/ula/opt/superpowers/<commit>`, from a tarball of a fixed commit
(v7.0.2, `22f0b463`) with a pinned sha256. Because it is a local directory pinned to a
commit, OpenCode treats it as immutable and never updates it. `ULA_SUPERPOWERS=0` or
`--no-superpowers` leaves it out.

**Models and templates** are verified against the sha256 in `catalog/models.tsv` and
`catalog/templates.tsv`, as described above.

## Risks

**Hugging Face takedowns.** HF removes individual uncensored repos, mostly those branded
for offensive cyber. One GLM-5.3 build was disabled under the Content Policy, and a Kimi
abliterated repo started returning 404. A catalog row can stop working overnight.

- `ula catalog verify` reports such a row as `FAIL` with its HTTP code. Run it monthly or
  in CI.
- **Mirror the files you depend on**, together with the repo's README and LICENSE, on a
  disk you control. Setting `ULA_MODELS_DIR` to an external SSD keeps the working copies
  there as well. This matters most for files on personal accounts, such as the gghfez
  gpt-oss-120b file.
- To restore from a mirror, copy the GGUF into `ULA_MODELS_DIR` under its catalog file
  name and run `ULA_REVERIFY=1 ula pull <alias>`. That re-checks the sha256 of local files
  instead of skipping them.
- If a repo disappears, point the row at another mirror of the **same file**. The pinned
  sha256 proves the bytes are identical. A different file is a new row.

**Tool calling of abliterated models has not been independently benchmarked.** No BFCL,
tau2, SWE-bench or Terminal-Bench results exist for any abliterated build. The available
evidence (IFEval within ±1 point; most tool-call failures in practice come from chat
templates and runtimes) suggests the edit is not the main risk, but it has not been
proven. 4-bit quantization alone can raise tool-name hallucinations up to 2.5x while
headline scores stay flat. Before trusting a build:

1. Run `ula test <alias>`. It covers a plain chat, a plain tool call, a tool call after
   a **late system message**, and the `:fast` alias. The Qwen rows use the fixed template,
   which accepts a late system message; the stock Qwen and Nanbeige templates raise an
   exception on it. `ula test` reports a rejected late system message as a warning, not
   a failure, because OpenCode and superpowers do not send one.
2. Run your own eval, and the same eval on the `-stock` alias, under OpenCode with the
   same quantization. Count invalid JSON, wrong tool names, repeated calls and unclosed
   `<think>` blocks, not only task success.
3. Check what the agent produced rather than what it reports. Some local models write
   placeholders and then report success.

**Untested profiles.** 13 of the 15 profiles have never been run. Their budgets assume
compute buffer sizes and GPU limits that may be wrong on your machine. Expect to lower a
context or an offload setting, and please report what you find.

**Other things that break quietly:**

- Parser fixes for Qwen3.x tool calls landed in llama.cpp through late October 2026.
  `ULA_LLAMA_CPP_TAG` is pinned to `b12176`, and the pin should be raised deliberately,
  together with new hashes in `catalog/binaries.tsv`, followed by `ula test`.
- OpenCode's `limit.context` must equal `--ctx-size`, or OpenCode assumes 200K and never
  compacts. `ula render` derives both from the profile's `ctx`, so change `ctx` there and
  not in the generated files.
- Benchmarks drift. The scores in this page and in the catalog comments are from
  2026-11-06. Re-check UGI, Artificial Analysis and Vals before replacing a model, and
  remember that vendor self-reports and independent numbers can differ wildly on agentic
  benchmarks (Beam 1.0: 80.1% self-reported on Terminal-Bench 2.1, 4.04% on Vals TB4).
