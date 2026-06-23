# JarvisOSLinux — Issue Backlog (Priority Order)

## Legend
- [ ] pending
- [~] in progress
- [x] done

---

## Needs Your Input

### [Project-JARVIS#83] SCCL v1 — confirm sustainability of legal documents
**Issue:** https://github.com/JarvisOSLinux/Project-JARVIS/issues/83

Decisions needed before this can be finalized:
- **Jurisdiction** — Article 8.3, which country/state governs the license
- **Legal review sign-off** — external counsel review of SCCL, Charter, CLA

Note: K₁/K₂/activation threshold/fund allocation/cure period all resolved (see issue history). CLA and C-points docs drafted (PR #102). Remaining blocker is jurisdiction decision and legal counsel sign-off.

---

### [Project-JARVIS#86] Draft governance documentation (Organization Charter)
**Issue:** https://github.com/JarvisOSLinux/Project-JARVIS/issues/86
**Blocked by:** #83 (jurisdiction + legal review)
**Draft PR:** #104 (DRAFT — full charter drafted, awaiting #83 resolution)

Charter is written. Remaining decisions:
- **Legal entity type** — foundation / non-profit / LLC
- **Jurisdiction** — same as #83

---

## Open — Ready to Merge

### [Project-JARVIS] PR #125 — Cross-platform support
**Issue:** https://github.com/JarvisOSLinux/Project-JARVIS/issues/123 (closed)
**PR:** https://github.com/JarvisOSLinux/Project-JARVIS/pull/125 — not draft, MERGEABLE

Adds `jarvis/platform/` (LinuxPlatform / MacOSPlatform / WindowsPlatform) auto-selected at import time. Abstracts IPC socket, socket security, config/data paths, desktop notifications, Ollama service control, signal handlers. All consumers updated.

---

### [Project-JARVIS] PR #126 — Doc audit + rewrite
**Issue:** https://github.com/JarvisOSLinux/Project-JARVIS/issues/121 (closed)
**PR:** https://github.com/JarvisOSLinux/Project-JARVIS/pull/126 — not draft, MERGEABLE

CLAUDE.md Key Files table fixed; README Quick Start + install step 7 updated; new `docs/architecture.md`; `docs/tui-overview.md` rewritten; 5 stale docs deleted.

---

## Needs Resolution Before Merge

### [dmcp] PR #2 — Unit tests (27 tests)
**PR:** https://github.com/JarvisOSLinux/dmcp/pull/2 — DRAFT + CONFLICTING (merge conflicts)

Covers models, discovery, paths, sources. Needs conflict resolution before it can merge.

---

## Submodule State (2026-06-23 — after today's session)

| Submodule | Pinned | Status |
|-----------|--------|--------|
| Project-JARVIS | `5e9cc54` (JarvisOSLinux/main, v1.0.0) | Up to date — bumps after PR #125/#126 merge |
| dmcp | `c830e64` | Up to date |
| dispatch | `706680a` (CI + notify-parent) | Up to date |
| linux-jarvisos | `f5db0e2` (path-based policy) | **Up to date** — bumped today |

Open PRs not yet merged to main (not yet pinnable):
- **Project-JARVIS PR #125** — cross-platform layer (#123) — ready to merge
- **Project-JARVIS PR #126** — doc audit (#121) — ready to merge
- **dmcp PR #2** — unit tests — draft + conflicts, needs work

---

## Completed This Session

- [x] **jarvisos submodule bump** — Project-JARVIS `5d1af84` → `5e9cc54` (JarvisOSLinux/main v1.0.0); switched .gitmodules to org canonical; dispatch `86b9c99` → `706680a`
- [x] **Project-JARVIS#123** — Cross-platform abstraction layer `jarvis/platform/` (PR #125, issue closed)
- [x] **Project-JARVIS#121** — Doc audit + rewrite: CLAUDE.md, README, new architecture.md, tui-overview rewrite, 5 stale docs deleted (PR #126, issue closed)
- [x] **linux-jarvisos path-based policy** — `jarvis_policy.c` + `jarvis_policy.h` + UAPI extended with `path_prefix`/`path` fields; 10 default FORBIDDEN/DANGEROUS rules; PR #2 merged; jarvisos pin bumped `1a211ae` → `f5db0e2`
- [x] **Kernel 7.1.1 build** — Clean build (exit 0, 0 errors) on Linode g6-dedicated-48 (48 vCPU, us-lax); 4 packages downloaded to `kernel-pkg/v7.1.1/`; checksums verified; Linode deleted

---

## Completed (prior sessions)

- [x] **jarvisos#6** — PolicyKit rules for JARVIS privilege escalation (PR jarvisos#7)
- [x] **Project-JARVIS#100** — TUI provider add/edit modal (PR #101)
- [x] **Project-JARVIS#96** — Appendix A fee formula constants (PR #102)
- [x] **Project-JARVIS#97** — Appendix C CLA draft (PR #102)
- [x] **Project-JARVIS#98** — Appendix D C-points methodology (PR #102)
- [x] **mcp-registry#18** — Third-party submission path (PR mcp-registry#19)
- [x] **Project-JARVIS#77** — End-to-end installability + CI (PR #103)
- [x] **dmcp#11** — Polkit root privilege for system-scoped servers (PR dmcp#18)
- [x] **dmcp#5** — @mcp.tool docstring description fallback (PR dmcp#19)
- [x] **jarvisos-website#6** — Website redesign polish (PR jarvisos-website#7)

---

## Previously Completed

- [x] **Project-JARVIS#78** — API recycling: provider failover with cooldown + priority
- [x] **Project-JARVIS#79** — TUI settings: context visibility + settings modal
- [x] **Project-JARVIS#89** — Session-scoped MCP server buffer in system prompt
- [x] **dispatch#5** — Search descriptions from `@mcp.tool` doc comments (MERGED)
- [x] **Project-JARVIS#93** — Fix: Jarvis not responding after 11 Ollama retries
- [x] **Project-JARVIS#92** — Fix: /rename breaks on spaces and special characters
- [x] **Project-JARVIS#87** — Review and proofread CONTRIBUTING.md (closed)
- [x] **Project-JARVIS#85** — Add CODE_OF_CONDUCT.md (closed)
- [x] **mcp-registry#17** — Add real functional MCP servers to registry (closed)
- [x] **Project-JARVIS#109** — Per-provider temperature (merged)
- [x] **Project-JARVIS#108** — Unified ConfigModal (merged #115)
- [x] **Project-JARVIS#107** — Lazy provider init (merged #113)
- [x] **Project-JARVIS#106** — Ollama auto-start (merged #116)
- [x] **Project-JARVIS#117** — Dispatch-scoped MCP docs (merged #118)
- [x] **Project-JARVIS#114** — Remove legacy .env config (merged)
- [x] **Project-JARVIS#119** — Dead code + ROOT PID linking fix (merged)
- [x] **Project-JARVIS#120** — Dispatch naming clarification docs (merged)
- [x] **Project-JARVIS v1.0.0** — Release prep: publish workflow, PyPI rename (PRs #122, #124)
