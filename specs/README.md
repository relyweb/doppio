# Design specs

Versioned design docs for Doppio features, following spec-driven development:
each spec is written and reviewed **before** implementation, committed alongside
the code, and kept as the historical record of *why* a change was made.

Kept in `specs/` (not `docs/`, which is the published GitHub Pages site).

## Status lifecycle

Every spec carries a `Status:` in its header, advanced as the work moves:

- **Draft** — under discussion / review; not yet agreed.
- **Accepted** — approved; implementation may proceed.
- **Implemented** — shipped; the *code* is now the source of truth. The spec
  stands as the historical record, and durable decisions are folded into
  `README.md` / `AGENTS.md`.
- **Superseded** — replaced by a later spec (link the replacement).

Specs are **point-in-time records, not living docs** — don't try to keep every
spec in sync with the code forever. Advance the status; once *Implemented*, trust
the code and `AGENTS.md` for current behavior.

## Index

| Date | Spec | Status |
|------|------|--------|
| 2026-08-17 | [Claude Code auto-resume (CLI-only MVP)](2026-08-17-claude-code-auto-resume-design.md) | Accepted |
