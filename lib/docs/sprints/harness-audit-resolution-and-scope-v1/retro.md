# Retro — harness-audit-resolution-and-scope-v1

**Slug:** harness-audit-resolution-and-scope-v1
**Closed:** 2026-05-19
**Duration:** single autonomous session (~5h elapsed; nominal 14-day walked end-to-end via compressed timeline)
**Scope:** 19 ACs closing the 2 load-bearing harness gaps + the 10 HAR security findings from prior sprint.

## What worked

The audit-resolution-phase DESIGN survived first contact with reality. New phase exit predicate (`audit_resolution_complete`) evaluated pure-state.json arithmetic as architect ship-gate C1 required. The 4 live findings from this sprint's audit (3 Accept + 1 Defer to `harness-key-rotation-v1`) walked through `sprint-audit-resolve.sh --finding HAR-N action` programmatic mode without UX issues. Per-decision atomic persistence (C2) verified by the gates_passed[] entries for each `audit-finding-HAR-N-{accepted,deferred}`.

Scope-bounding (W1) prevented this sprint from being blocked by the same 10 pre-existing `.claude/helpers/*.js` findings that bypassed prior sprint. Live audit ran in 36s + testgaps in 514s + optimize in 302s — total verify worker fire ~14 min. Workers produced 4 in-scope findings (LOW severity nits about W3 fixes) which proved both that scope-bounding works AND that the audit-resolution flow exercises the full chain.

The W2 bug discovered (audit JSON schema is `.findings.vulnerabilities[]`, not top-level) is a real find. Without W1's smoke against prior sprint, this would have stayed hidden — `gate_audit_blocks` had been silently counting 0 vulnerabilities for any non-legacy schema. Fixed retroactively via union-path filter.

## What didn't

The verify-worker-audit gate bypass mechanic is awkward — when audit finds in-scope findings, the gate FAILS the verifying phase predicate. Operator must bypass with "handed off to audit-resolution" rationale before advancing. Cleaner UX would be: verifying advances unconditionally; audit-resolution phase reads the audit.json directly and gates on its own predicate. Filed as v0.7.3 polish.

Operator-typed rationale fields (Accept + Defer) go through `sprint-pii-redact.sh` (C5) but the redaction is silent — there's no operator feedback like "redacted 3 patterns" so the operator can't tell if their input was modified. Functional but UX-thin. Filed as v0.7.3 polish.

The W3 audit FOUND 4 LOW findings about the W3 fixes themselves. Two were about defense-in-depth choices (intentional). One (HAR-3 memory.js MAC) is a real follow-up item. One (HAR-4 github-safe.js out-of-scope shell-meta) was actually out-of-scope per the new partition logic but still flagged because the audit worker doesn't know about scope. This is by design (scope filter happens at gate-eval, not worker-invoke per ADR-001) — but it shows up as noise in the resolution walk.

## What surprised us

The audit-resolution phase's exit predicate succeeded with a MIX of resolved=0 + deferred=1 + accepted=3 (total=4). That's the canonical "operator triaged everything" outcome — not "all fixed in-sprint." It validates the design: the phase isn't "fix everything," it's "decide everything." Future sprints with real vulnerabilities will have a different mix (resolved>0 + deferred named-to-follow-up + accepted with risk owner).

Worker_runs[] now tracks 8 invocations across this sprint (map ×2 + predict + audit + testgaps + optimize + document + consolidate). This is the same footprint as `harness-parallel-safety-v2` baseline. C-base scope-bounding + W2 wrap-into-advance-phase + audit-resolution all working together produced the canonical sprint worker pattern operators should expect.

## Patterns extracted

### Pattern 1: `lifeos-scope-bound-at-gate-eval`

**Symptom:** Audit/testgaps worker runs against entire repo, producing 10+ pre-existing findings on every sprint regardless of files touched. 100% noise.
**Fix:** Scope-filter at GATE EVAL time (not at worker-invocation time). Mirror `gate_testgaps_blocks` pattern — read state.json.files_touched[] (or spec.md ## Files touched fallback), partition findings, count only in-scope as blocking. Out-of-scope findings logged as advisory.
**Where applied:** W1 — `gate_audit_blocks` accepts `<slug>` arg + state.json-first scope source.
**Generalizes to:** any audit-style worker that scans whole codebase. Scope-filter is the right insertion point because it leaves the worker alone (no prompt template touching) and the filter is deterministic from state.json.

### Pattern 2: `lifeos-audit-finding-explicit-triage`

**Symptom:** Audit produces findings late in sprint; operator bypasses with vague rationale to ship; findings silently lost in `gate_bypasses[]`.
**Fix:** New `audit-resolution` phase between `verifying` + `pre-deploy`. Mandatory `audit-resolutions.md` triage doc seeded from `_templates/`. Each finding becomes Fix (resolved in-sprint via `sprint-audit-rerun.sh`) OR Defer (REQUIRED follow-up sprint + AC ID) OR Accept (REQUIRED risk owner + business rationale). Exit predicate `audit_resolution_complete` blocks pre-deploy until resolved + deferred + accepted == total.
**Where applied:** W2 — new phase + sprint-audit-resolve.sh + sprint-audit-rerun.sh.
**Generalizes to:** ANY blocking-verify gate that produces a finding list. Same pattern: declared resolution phase + interactive walker + per-decision atomic persistence + exit predicate validates arithmetic.

### Pattern 3: `lifeos-node-builtin-crypto-encryption`

**Symptom:** Helper files (memory.js, session.js) stored sensitive context as plaintext JSON. Adding libsodium / tweetnacl would add deps + license review.
**Fix:** Node built-in `crypto` module (aes-256-gcm + `createCipheriv` + `scryptSync` key derivation + `crypto.randomBytes(32)` key generation). Single key file at `~/.claude-flow/.encryption-key` with 0600 perms + post-create perm-verify on every load. keyVersion in encrypted envelope for future rotation. Atomic migration via .tmp + O_EXCL + fsync + rename.
**Where applied:** W3 HAR-2 + HAR-4 — memory.js + session.js share encryption stack.
**Generalizes to:** any "store sensitive data at-rest in this monorepo" need. Node built-in crypto is zero-dep, license-clean, FIPS-validated in modern Node. Avoid pulling libsodium unless you need streaming or x25519 specifically.

## CLAUDE.md updates proposed

- Root `CLAUDE.md`: phase-workers.json + audit-resolution phase already documented in DEVELOPER.md. No new updates.
- `apps/web/CLAUDE.md`: out of scope (no app code).

## Open follow-ups

- **`harness-key-rotation-v1`** (MUST land before v0.9.0): key rotation policy + MAC on key file (HAR-3 deferred from this sprint). Single appetite.
- **`harness-continuous-verification-v1`** (v0.8+): mid-build verify pulses between waves. Requires ruflo light-worker variants — still blocked.
- **`v0.7.3 polish`**:
  - verify-worker-audit gate UX: cleaner "handed off to audit-resolution" semantics (no bypass needed).
  - sprint-pii-redact.sh feedback: log how many patterns were redacted so operator can verify.
  - audit-driven-fidelity-v1 state.json fix: pre-existing legacy bypass schema (uses `reason` field instead of canonical `why`) — surfaces in replay validator.
- **v0.8.0**: legacy SPRINT\_\*\_BYPASS removal. Requires harness-key-rotation-v1 landed first.
- **Push to origin (gio approval)**: 250+ commits ahead on `sprint/pipeline-v2-visibility`. Awaiting explicit confirmation.

<!-- auto-appended by sprint-end.sh document worker -->

### document worker proposals (2026-05-19T18:58:46Z)

````json
{
  "timestamp": "2026-05-19T18:58:44.238Z",
  "mode": "headless",
  "workerType": "document",
  "model": "haiku",
  "durationMs": 18307,
  "executionId": "document_1779217105931_mky85o",
  "success": true,
  "findings": {
    "sections": [],
    "codeBlocks": []
  },
  "rawOutputPreview": "I'll help you generate documentation for undocumented code. However, I need to clarify the scope first:\n\n1. **Which modules/files** should I focus on? (e.g., specific Lambda handlers, React components, utility libraries, API routes)\n2. **Documentation depth**: Should I generate comprehensive docs (README + JSDoc + examples) or focus on JSDoc comments only?\n3. **Priority areas**: Are there specific APIs or modules that are blocking other developers?\n\nOnce you point me to the code, I'll:\n- Add JSDoc with `@param`, `@returns`, `@throws`, `@example` tags\n- Create module READMEs where needed\n- Document all public APIs with usage examples\n- Add inline comments for non-obvious logic (avoiding over-commenting obvious code)\n\nFor example, are you looking to document:\n- Lambda handlers in `apps/lambdas/`?\n- React components in `apps/web/`?\n- Shared utilities in `packages/`?\n- All of the above?\n",
  "rawOutputLength": 896
}```
````
