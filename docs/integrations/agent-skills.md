# agent-skills Integration (Council Lifecycle Prompt Packs)

Status: Adopted
Owner: MSS Group / Sai
Purpose: Give every AMOS agent a shared, production-grade engineering lifecycle — Spec -> Plan -> Build -> Test -> Review -> Ship — instead of ad-hoc prompts, so the Agent Council (Phase D) executes consistently.

Upstream: https://github.com/addyosmani/agent-skills
License: MIT

---

## 1. Why agent-skills

The master spec's Codex implementation loop and Agent Council describe *who* does *what*, but not the concrete workflow each agent follows. agent-skills packages the workflows, quality gates, and best practices senior engineers use, as slash commands and skill files compatible with Claude Code, Codex, Cursor, Gemini CLI, and any Markdown-instruction agent. This fills Phase D ("Council Operations") directly: it is the shared prompt-pack standard the council runs on.

## 2. Lifecycle and Commands

| Phase | Command | Purpose |
|---|---|---|
| Define | `/spec` | Specification before code |
| Plan | `/plan` | Break work into atomic tasks |
| Build | `/build` | Implement incrementally (`/build auto` = plan + implement in one approved pass) |
| Test | `/test` | Test-driven verification |
| Review | `/review` | Quality gates before merge |
| Ship | `/ship` | Production deployment |
| Audit | `/webperf` | Performance analysis |
| Simplify | `/code-simplify` | Reduce complexity |

## 3. Mapping to AMOS Agent Roles

The lifecycle maps onto the existing roles in master spec section 2. No new agents are introduced; each agent gains an explicit phase and skill set.

| AMOS Role | Owns phases | Primary skills |
|---|---|---|
| Gemini / Jules (intake) | Define | interview-me, idea-refine, spec-driven-development |
| Claude (architect / review) | Define, Plan, Review | spec-driven-development, planning-and-task-breakdown, code-review-and-quality, code-simplification |
| GPT / Codex (implementation) | Build, Test, Ship | incremental-implementation, test-driven-development, api-and-interface-design, git-workflow-and-versioning, ci-cd-and-automation, shipping-and-launch |
| OpenClaude (safety gate) | Review | security-and-hardening, code-review-and-quality |
| Open Cowork (GUI operator) | Ship (report/sync) | documentation-and-adrs, observability-and-instrumentation |

This preserves the AMOS flow: Jules structures intake -> Claude specs/plans -> Codex builds/tests -> OpenClaude gates safety -> Codex ships. Human sovereign approval (Layer 12) remains the final step; `/ship` never bypasses it.

## 4. Installation

Universal CLI (installs into the target agent):

```bash
npx skills add addyosmani/agent-skills
# single skill:
npx skills add addyosmani/agent-skills --skill spec-driven-development
```

Per-agent alternatives:

```bash
# Claude Code (plugin marketplace)
/plugin marketplace add addyosmani/agent-skills
/plugin install agent-skills@addy-agent-skills

# Codex
codex plugin marketplace add addyosmani/agent-skills

# Gemini CLI
gemini skills install https://github.com/addyosmani/agent-skills.git --path skills
```

## 5. Rollout Plan

1. Install the Review + Define skills first — they align with the current priority (agent prompt packs, OpenClaude safety gate).
2. Wire `/spec` and `/plan` into the Jules -> Claude intake handoff.
3. Add `/review` (code-review-and-quality, security-and-hardening) to the OpenClaude PR-review step (`scripts/openclaude_pr_review.py`) so the local gate follows the same checklist.
4. Adopt `/build` and `/test` in the Codex after-merge implementation loop.
5. Keep `/ship` gated behind human approval per Layer 12.

## 6. Guardrails

- MIT-licensed; safe to vendor or reference.
- Skills are instructions, not automation — they do not merge or deploy on their own, so Non-Negotiable Rules 6 and 7 (review before destructive action, human approval for live money) still hold.
- Manual fallback: agents can operate without the skill packs (ad-hoc prompts) if the CLI is unavailable; behavior degrades in consistency, not capability.
