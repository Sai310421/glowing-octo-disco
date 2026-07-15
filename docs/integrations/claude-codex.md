# Claude Codex Implementer (Autonomous Layer 05)

Status: Adopted — requires one secret to activate
Owner: MSS Group / Sai
Purpose: Fill the AMOS "Codex" implementation role with an autonomous Claude
agent running in CI, so EA/dev tasks are implemented without depending on
any OpenAI/GPT plan or its quota.

Upstream action: https://github.com/anthropics/claude-code-action

---

## 1. What it does

The AMOS "Codex" role (master spec section 2.1) is a *role*, not a fixed
product. This wires that role to Claude:

1. A merge of a real knowledge packet (`docs/inbox/`) or EA code (`ea/`)
   triggers the Codex dispatcher (`03_codex_after_merge.yml`), which opens
   an issue labeled `codex-ready`.
2. `05_claude_codex_implementer.yml` reacts to that label: Claude reads the
   task, implements under `ea/`, adds validation under `reports/`, and opens
   a pull request. It never pushes to `main`.
3. The OpenClaude gate (`02_openclaude_review.yml`, Layer 04) reviews the
   new PR and merges it if safe.

You can also trigger it manually by adding the `codex-ready` label to any
issue.

## 2. Activation (one-time)

The workflow is inert until you add one repository secret:

- Go to **Settings > Secrets and variables > Actions > New repository secret**.
- Name: `ANTHROPIC_API_KEY`
- Value: an Anthropic API key.

Notes:
- This is an **Anthropic** key. It is independent of your OpenAI/ChatGPT
  Codex subscription and of OpenAI API billing — GPT quota being exhausted
  does not affect it.
- Until the secret exists, the workflow runs but no-ops with a warning, so
  nothing breaks.

## 3. Guardrails

- Claude opens a PR; it never pushes to `main`. Human approval (Layer 12)
  and the OpenClaude safety gate (Rules 5/6) still apply before merge.
- If an issue has no actionable EA logic, the agent comments and stops
  instead of inventing a strategy.
- `--max-turns 40` bounds each run. Adjust in the workflow's `claude_args`.
- Model selection is the action default; pin one with
  `claude_args: "--model <id> --max-turns 40"` if desired.

## 4. Cost strategy

Route these runs through Headroom (see `docs/integrations/headroom.md`) to
cut token cost while cloud LLMs are in use. When local AI is operational,
the same implementer role can move to a self-hosted/local model.

## 5. Manual fallback

If the action is unavailable or the secret is unset, the `codex-ready`
issues remain as a normal backlog that a human (or an interactive Claude
Code / Codex session) can implement by hand. No AMOS step hard-depends on
this automation.
