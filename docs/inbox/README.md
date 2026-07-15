# AMOS Inbox (Knowledge Packet Drop Zone)

This directory is the entry point for structured AMOS Markdown knowledge
packets produced from Issue intake (Layer 02 -> Layer 03).

## How it flows

1. Gemini/Jules converts a GitHub Issue into an AMOS Markdown packet using
   `docs/templates/amos_standard.md`.
2. The packet is committed here as `docs/inbox/<topic>.md`.
3. On merge to `main`:
   - `04_notebooklm_export.yml` exports packets for NotebookLM ingestion
     (Layer 07).
   - `03_codex_after_merge.yml` dispatches a Codex implementation task when
     the packet contains EA/dev work (Layer 05).

## Rules

- One packet per file. Name files by topic, not date.
- Every packet must follow the standard template sections.
- No secrets. No unvalidated trading claims (see Non-Negotiable Rules).

This README keeps the directory present so the NotebookLM export path is
always runnable, even when no packets are queued.
