# AMOS Level 50 Master Specification

Status: Foundation Specification
Owner: MSS Group / Sai
Purpose: Complete the AMOS Level 50 architecture through cooperative execution by GPT/Codex, Claude, Gemini/Jules, OpenClaude, and local automation agents.

---

## 1. Core Intent

AMOS Level 50 is not a single chatbot, script, or repository. It is a sovereign autonomous multi-agent operating system designed to coordinate:

- EA development
- Strategy research
- Backtesting and Monte Carlo validation
- GitHub-based SSOT knowledge management
- NotebookLM knowledge digestion
- SNS/content operations
- Business documentation
- Risk governance
- Human-in-the-loop approval
- Local AI cost reduction
- Future Open Cowork GUI operation

The repository is the central command room. All agents must treat this repository as the SSOT.

---

## 2. Agent Roles

### 2.1 GPT / Codex
Role: Senior DevOps architect and implementation lead.

This is a *role*, not a fixed product. It can be filled by GPT/Codex, by an
autonomous Claude implementer in CI (see `docs/integrations/claude-codex.md`),
or by a human, so implementation never depends on a single vendor's quota.

Responsibilities:
- Convert AMOS Markdown into executable code.
- Build EA, Python, CI/CD, validation scripts, and orchestration glue.
- Maintain technical quality gates.
- Create implementation PRs.

### 2.2 Claude
Role: Strategic architect, specification refiner, long-form reasoning layer.

Responsibilities:
- Refine AMOS Level 50 architecture.
- Improve doctrine, governance, prompt systems, and operational manuals.
- Review whether implementation matches the intended system design.

### 2.3 Gemini / Jules
Role: Multimodal intake and transformation agent.

Responsibilities:
- Convert iPhone text, voice transcripts, images, and video URLs into AMOS Markdown.
- Open PRs containing structured knowledge packets.
- Keep intake friction extremely low.

### 2.4 OpenClaude
Role: Local free review and safety gate.

Responsibilities:
- Review PRs locally using Ollama.
- Detect unsafe diffs, secrets, destructive commands, or malformed AMOS Markdown.
- Approve and merge safe PRs.

### 2.5 Open Cowork
Role: Desktop GUI operator.

Responsibilities:
- Operate desktop apps.
- Generate reports.
- Sync selected outputs to Notion or other human-facing workspaces.

---

## 3. Level 50 Architecture Layers

### Layer 01: GitHub SSOT
All decisions, specs, EA logic, markdown packets, and implementation tasks are stored in GitHub.

### Layer 02: Issue Intake
User can submit raw thoughts from iPhone via GitHub Issues.

### Layer 03: Jules Multimodal Structuring
Issues are transformed into AMOS Markdown packets.

### Layer 04: OpenClaude Local Review
Local LLM reviews PRs before merge.

### Layer 05: Codex Implementation Dispatch
Merged knowledge automatically creates implementation tasks. A `codex-ready`
task can be implemented autonomously by a Claude agent in CI
(`05_claude_codex_implementer.yml`), which opens a PR for the OpenClaude
gate to review — no OpenAI/GPT quota required.

### Layer 06: EA Code Factory
MQL5, Python, Pine, and validation code are generated and improved through PRs.

### Layer 07: NotebookLM Knowledge Export
Markdown packets are exported for NotebookLM ingestion.

### Layer 08: Backtest and Monte Carlo Layer
All strategy claims must be validated. Monte Carlo reporting must prioritize P10/worst-decile results.

### Layer 09: Risk Governor
No EA is considered deployable without risk, DD, margin, and black-swan controls.

### Layer 10: SNS / Content Engine
Knowledge packets may generate SNS ideas, scripts, and publication workflows.

### Layer 11: Agent Council
GPT, Claude, Gemini, OpenClaude, and optional local models form a review council.

### Layer 12: Human Sovereign Approval
Final deployment decisions remain under Sai approval.

### Layer 13: Context Compression (Interim)
Headroom compresses tool outputs, logs, RAG chunks, files, and conversation history before they reach cloud LLMs (Claude, Codex, Gemini), cutting token consumption by 60-95%. This is an **interim cost-reduction layer** adopted until local AI (OpenClaude / self-hosted models) carries the bulk of inference. Compression is local-first and reversible, so no knowledge is lost and no secrets leave the machine. See `docs/integrations/headroom.md`. Retirement is re-evaluated once local AI is operational.

---

## 4. Definition of Done for AMOS Level 50

AMOS Level 50 is considered complete only when all items below are operational:

- GitHub repository works as SSOT.
- iPhone Issue intake is operational.
- Jules/Gemini can generate AMOS Markdown PRs.
- OpenClaude local runner can review PRs.
- Safe PRs can be merged automatically.
- Merge events create Codex implementation issues.
- EA code factory has folder structure and validation scripts.
- NotebookLM export path exists.
- Risk governance specification exists.
- Monte Carlo P10 reporting rule is enforced.
- Agent roles are explicitly documented.
- Manual fallback paths exist for every automation layer.

---

## 5. Immediate Roadmap

### Phase A: Foundation
- Repository setup
- Workflows
- OpenClaude installation
- Markdown template
- Codex dispatch

### Phase B: Knowledge Operations
- NotebookLM export
- Intake classification
- Issue templates
- Agent-specific prompt packs
- Headroom context compression (interim cost layer, active until local AI is operational)

### Phase C: EA Factory
- MQL5 project structure
- Compile workflow
- Backtest reporting format
- Monte Carlo validator

### Phase D: Council Operations
- Claude review prompt
- Gemini/Jules intake prompt
- Codex implementation prompt
- OpenClaude safety prompt
- Adopt the agent-skills lifecycle (Spec -> Plan -> Build -> Test -> Review -> Ship) as the shared prompt-pack standard, mapped to AMOS agent roles (see `docs/integrations/agent-skills.md`)

### Phase E: Full AMOS Runtime
- Discord command center
- Activepieces/n8n orchestration
- Vector memory
- VPS/MT5 runner
- Open Cowork GUI automation

---

## 6. Non-Negotiable Rules

1. GitHub is the SSOT.
2. NotebookLM is a knowledge digestion layer, not the primary SSOT.
3. No trading claim is accepted without validation.
4. Monte Carlo must report P10/worst-decile when used.
5. No secrets are committed.
6. No destructive automation is merged without review.
7. Human approval remains mandatory for live-money deployment.
8. Agent outputs must become files, PRs, Issues, or reports.

---

## 7. Current Status

Foundation layer is largely in place.

Operational now:
- OpenClaude PR review gate runs on a GitHub-hosted runner and enforces
  secret/destructive-command checks before auto-merge (Layer 04).
- Codex dispatch fires only on real knowledge packets (`docs/inbox/`) and
  EA code, not on every doc edit (Layer 05).
- Autonomous Claude implementer reacts to `codex-ready` labels and opens
  implementation PRs (`05_claude_codex_implementer.yml`); activate by adding
  a `CLAUDE_CODE_OAUTH_TOKEN` secret (Claude subscription, no API billing).
  Vendor-independent — no GPT quota needed.
- NotebookLM export path has a live source directory (`docs/inbox/`,
  Layer 07).
- EA factory scaffold (`ea/`, `reports/`) and Monte Carlo validator
  (`scripts/monte_carlo_validate.py`) exist (Layers 06/08).
- Risk Governor specification (`docs/RISK_GOVERNOR.md`, Layer 09).
- AMOS intake Issue template.
- Headroom (interim) and agent-skills adopted as documented standards.

Next priority:
- Wire the Monte Carlo validator and Risk Governor into the EA pipeline as
  enforced CI checks.
- Implement the shared `ea/include/` risk module.
- First real EA strategy from a `docs/inbox/` packet.
- Move OpenClaude to a local Ollama-backed self-hosted runner once local AI
  is operational (retire Headroom per its exit criteria).
