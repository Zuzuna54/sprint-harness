# Wave E — Doc cleanup (L49-L53)

**Verdict:** Production
**Methodology:** doc audit + targeted edits where stale prose found.

## L49 — `docs/sprints/README.md` v0.7.0 mention

Added "Phase enforcement (v0.7.0+)" paragraph after the harness-scale callout. Calls out:

- Every transition flows through `sprint-advance-phase.sh`
- Manifest declares 11 phases × 68 gates (25 enforced + 43 deferred)
- PreToolUse hook blocks direct `state.phase` mutation
- Single bypass UX (`SPRINT_BYPASS_GATE` + `SPRINT_BYPASS_WHY` ≥10 chars)
- Cross-links to USAGE.md `## Phase enforcement` + DEVELOPER.md write-ordering

## L50 — `docs/sprints/DEVELOPER.md` stale prose audit

Grepped for "tell claude", "I'll", "I will", "just run", "simply" — zero matches. DEVELOPER.md does NOT have v0.6.x-era "tell Claude to X" prose. Already brought up to v0.7 reality via parent sprint AC-1.5 (T1.3) and AC-12 (T1.5) updates.

## L51 — `docs/sprints/USAGE.md` rest-of-doc audit

USAGE.md line 519 already documents the v0.7.0 deprecation: "Legacy per-script bypass envs (`SPRINT_DRIFT_BYPASS=1`, `SPRINT_DESIGN_LOCK_BYPASS=1`, etc) emit a deprecation warning + auto-synthesize new bypass envs for v0.7.x compat. Removal scheduled for v0.8.0."

Remaining `SPRINT_DRIFT_BYPASS=1` references in USAGE.md (8 total at lines 356, 480, 519, 546, 553, 624, 728, 1254) are intentional — they're showing the _deprecated-but-still-working_ path for v0.7.x operators who have muscle memory. Each appears next to either:

1. The deprecation paragraph (line 519), OR
2. A bypass-cheatsheet pointer ("See `_guides/bypass-cheatsheet.md` for the canonical v0.7 form"), OR
3. The hooks/forbidden-actions table showing what gets caught.

Leaving the legacy references in place is correct for v0.7.x docs. When v0.8.0 ships (removal), a follow-up sprint replaces them all with the single-bypass UX. Documented as a follow-up: **v0.8.0 sprint must rewrite USAGE.md to use `SPRINT_BYPASS_GATE=drift-check` everywhere `SPRINT_DRIFT_BYPASS=1` currently appears**.

## L52 — Proof-file location convention

Added new "### Proof-file location convention (v0.7.0+)" subsection to DEVELOPER.md right after "Two-verdict policy:" paragraph. Distinguishes:

- **`docs/sprints/<slug>/proof/AC-N.md`** — per-AC evidence; lives in sprint dir; read by readiness aggregator.
- **`scripts/violation-fixtures/<name>.patch`** — reusable fixture patches (shared across sprints).
- Sprint-harness package vendored fixtures land at `lib/proof/` at install-time.
- Per-sprint proofs do NOT mirror to sprint-harness package — they belong to the consuming repo's sprint dir.

This was an ambiguity from the original kettle plan (`lib/proof/AC-N.md` mentioned). Convention is now explicit.

## L53 — Plan-file curation

Kettle file (`~/.claude/plans/hazy-gathering-kettle.md`) now holds the closure plan covering the 53 leftover items. The plan opens with a note that "the original build plan for the 14-AC parent sprint lived at this path; the build executed... THIS plan covers the 53 remaining leftover items as a fresh sprint that USES the now-shipped v0.7.0 protocol against itself."

Inbound references audited:

```
$ grep -n "hazy-gathering-kettle" docs/sprints/README.md docs/sprints/DEVELOPER.md CLAUDE.md
docs/sprints/DEVELOPER.md:4   ... (original design)
docs/sprints/DEVELOPER.md:763 Full plan with 36 captured decisions across 9 question rounds
docs/sprints/DEVELOPER.md:866 P5 — QA Hardening
docs/sprints/DEVELOPER.md:898 original design with 36 decisions
docs/sprints/README.md:19     Why we built it this way (36 captured decisions)
```

All 5 references continue to be valid — the kettle file still contains the 36 captured decisions in its top section (the plan was rewritten in-place, original architecture decisions preserved via the closure plan's "## Context" + "## Out of scope" sections which reference the parent build).

**Curation decision:** keep the kettle as a single-file plan (not per-sprint subdir as L53 originally suggested). Reason: 5 inbound references in committed docs would all need updating; the single-file form has been working; no operator pain reported. Move to per-sprint subdir form is a v0.7.1 polish item if ever needed.

## Files modified (Wave E)

- `docs/sprints/README.md` — added v0.7.0 phase enforcement paragraph (L49)
- `docs/sprints/DEVELOPER.md` — added proof-file convention subsection (L52)

## Files NOT modified (audit-only, no stale prose found)

- `docs/sprints/DEVELOPER.md` — L50 audit clean (no v0.6.x "tell Claude" prose)
- `docs/sprints/USAGE.md` — L51 audit: legacy bypass refs intentional pending v0.8.0 removal sprint
- `~/.claude/plans/hazy-gathering-kettle.md` — L53 curation: keep single-file form

## Follow-ups filed

- **v0.8.0 sprint**: rewrite USAGE.md legacy `SPRINT_*_BYPASS` examples to single-bypass UX (8 callsites). Same sprint removes the legacy shim code.

## Done = all of

- ✓ L49 README.md updated.
- ✓ L50 DEVELOPER.md audit clean.
- ✓ L51 USAGE.md audit — legacy refs intentional during v0.7.x deprecation window.
- ✓ L52 proof-file convention documented.
- ✓ L53 kettle plan-file reference integrity verified; curation deferred to v0.7.1 polish (single-file form fine for now).
