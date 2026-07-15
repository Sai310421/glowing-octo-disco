# Headroom Integration (Interim Context Compression)

Status: Adopted — interim
Owner: MSS Group / Sai
Purpose: Reduce cloud-LLM token consumption by 60-95% across AMOS agents until local AI (OpenClaude / self-hosted models) carries the bulk of inference.

Upstream: https://github.com/headroomlabs-ai/headroom
License: Apache 2.0

---

## 1. Why Headroom, Why Now

The AMOS pipeline drives several cloud LLMs (Claude, Codex, Gemini/Jules) over large inputs — tool outputs, logs, RAG chunks, Markdown packets, and long conversation history. Those tokens are billed and grow fast under multi-agent loops.

Headroom compresses everything an agent reads **before** it reaches the LLM, keeping answer quality while cutting tokens. It is:

- **Local-first** — compression runs on the machine; nothing extra leaves it.
- **Reversible** — original content is cached locally and can be restored via `headroom_retrieve`, so no knowledge is lost.
- **Drop-in** — usable as a library, a proxy, or an MCP server.

This satisfies the master spec's "Local AI cost reduction" intent (Layer 13) without violating Rule 5 (no secrets committed / leaked).

## 2. Scope and Exit Criteria

This is an **interim** layer, not a permanent architecture commitment.

- **Active while**: AMOS agents run primarily on paid cloud LLMs.
- **Re-evaluate / retire when**: local AI (OpenClaude via Ollama, or a self-hosted model) handles the bulk of inference, at which point per-token cost is no longer the dominant constraint.
- Retirement is a review decision, not automatic — measure token/cost deltas before removing.

## 3. Installation

Requires Python 3.10+.

```bash
pip install "headroom-ai[all]"
# or
uv tool install "headroom-ai[all]"
```

TypeScript SDK (no CLI):

```bash
npm install headroom-ai
```

Docker:

```bash
docker pull ghcr.io/chopratejas/headroom:latest
```

## 4. Deployment Modes

Pick per agent; start with the proxy for zero-code coverage.

### 4.1 Proxy (recommended first step)
Zero code changes — point any OpenAI-compatible client at the local proxy.

```bash
headroom proxy --port 8787
```

### 4.2 MCP Server
Exposes `headroom_compress`, `headroom_retrieve`, `headroom_stats` as tools.

```bash
headroom mcp serve
```

### 4.3 Library
Import directly in `scripts/` when an agent needs fine-grained control over what gets compressed.

## 5. Configuration (env vars)

| Variable | Purpose |
|---|---|
| `HEADROOM_OUTPUT_SHAPER=1` | Also reduce output tokens (off by default) |
| `HF_HUB_OFFLINE=1` | Use the cached Kompress model without downloading |
| `HEADROOM_UPDATE_CHECK=off` | Disable update notifications (cleaner CI logs) |
| `HEADROOM_TLS_STRICT=0` | Relax TLS only if behind corporate SSL inspection |

Do not commit any machine-specific values or tokens — keep configuration in local env / untracked files (Rule 5).

## 6. AMOS Wiring

- **Codex / Claude / Gemini agents**: route through `headroom proxy` (§4.1) so implementation and review loops are compressed transparently.
- **RAG / NotebookLM path**: compress large Markdown packets and retrieved chunks before they enter a prompt; restore originals with `headroom_retrieve` when full fidelity is needed.
- **Validation**: record before/after token counts (`headroom_stats`) in `reports/` so the cost benefit is auditable and the exit decision (§2) is data-driven.

## 7. Manual Fallback

Per the master spec, every automation layer needs a manual path. If Headroom is unavailable, agents call their LLMs directly (uncompressed) — higher token cost, identical behavior. No AMOS step depends on Headroom being present.
