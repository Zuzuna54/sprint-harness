# Extending ACs mid-sprint

How to add a new acceptance criterion to a locked sprint without breaking drift / scope tracking.

---

## When to extend vs cut vs new-sprint

| Situation                                                       | Action                                                                       |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Discovered scope gap mid-build, work fits in remaining appetite | **Extend** — add new AC via amendment                                        |
| Sprint going over appetite, ACs at risk                         | **Cut** — remove non-essential ACs                                           |
| Major rework needed, breaks core assumption                     | **New sprint** — pause current, start follow-up                              |
| Quick drive-by fix unrelated to sprint goal                     | **Override drift once** — `SPRINT_DRIFT_BYPASS=1 git commit` (logs to retro) |

---

## Add AC to running sprint

### 1. Decide AC text

Follow the spec template — `**AC-<N>**` header, Gherkin for UI/E2E, INVEST for backend. Mark `complex: true` if it touches:

- `auth`, `authentication`, `authorization`
- `payment`, `billing`, `charge`
- `RLS`, `row-level`, `policy`
- `migration`, `schema change`, `drop table`
- `JWT`, `token`, `secret`, `credential`, `key`
- `delete`, `password`, `hash`, `encrypt`, `decrypt`

(Keyword list in `.claude/skills/sprint-spec-wizard/sections/I-acceptance.md` "Complex AC auto-detection".)

### 2. Amend the spec — strict mode (AC-31)

Either edit `spec.md` directly + `--lock`, or use the structured amendment path:

```bash
AMEND_WHY="Discovered on day 6: existing supplements UI lacks empty-state for new users" \
AMEND_INTENT="New users see a clear CTA to add their first supplement, not blank screen" \
AMEND_SCOPE_IMPACT="files_added: apps/web/components/supplements/EmptyState.tsx; ac_added: AC-12" \
AMEND_ACS_AFFECTED="AC-12" \
AMEND_ALTERNATIVES="Could defer to next sprint, but missing UX is visible in current user flow" \
AMEND_DECIDED_BY="user+Claude" \
  bash scripts/sprint-amend-spec.sh --add-file apps/web/components/supplements/EmptyState.tsx
```

Then manually edit `spec.md` to add the new AC block under §I.

### 3. Re-baseline drift

```bash
bash scripts/sprint-rebaseline.sh
```

Old baseline archived to `.baseline-embedding.day<N>.json`. New baseline reflects expanded spec.

### 4. Re-run pair-check

```bash
node scripts/sprint-pair-check.mjs <slug> --json | jq '.results[] | select(.requires_pair_mode)'
```

If the new AC has complex-keywords, pair-mode auto-triggers on its commits via the post-commit hook (AC-7).

### 5. Implement + close

Build as usual. When done:

```bash
bash scripts/sprint-amend-spec.sh --close-ac AC-12
```

This appends to `state.acs_closed_ids[]`, increments `acs_closed`, timestamps `acs_closed_at["AC-12"]`. The all-pass verify gate (AC-28) checks `acs_closed === acs_total` before allowing pre-deploy phase.

---

## Cut ACs (scope reduction)

When time-box warning fires at 110% appetite (AC-3), or you realize an AC is over-engineered:

```bash
AMEND_WHY="Sprint at day 12 of 14 with 3 ACs still open; cutting non-critical to ship core on time" \
AMEND_INTENT="Land 5 of 8 ACs cleanly; deferred 3 to next sprint backlog" \
AMEND_ALTERNATIVES="Could extend appetite, but Shape Up principle says cut not extend" \
AMEND_DECIDED_BY="user (day-5 checkin)" \
  bash scripts/sprint-amend-spec.sh --cut AC-6,AC-7,AC-8
```

This appends an `Amendment` block to `spec.md` and records to `state.scope_amendments[]` with action `scope-cut`.

The cut ACs become next-sprint backlog candidates — they appear in `docs/sprints/_index/capabilities.md` as `○` (not closed) entries.

---

## Files-touched scope (AC-7 hook enforcement)

The PreToolUse hook `.claude/helpers/sprint-hook.cjs` blocks Write/Edit of any file not in `state.files_touched[]`. To widen scope:

```bash
AMEND_WHY="..." AMEND_INTENT="..." \
  bash scripts/sprint-amend-spec.sh --add-file path/to/new/file.ts
```

The hook reads `files_touched` directly from `state.json` — no rebaseline needed unless you also want the drift score to reflect the new scope (recommended after multiple file adds).

---

## Anti-patterns

- **Editing `state.json` directly with `jq` skipping the amendment script** — loses the WHY+INTENT trail; AC-31 strict mode exists for this reason.
- **Adding 5+ files in one amendment** — usually means the sprint scope was wrong. Pause and re-spec.
- **`SPRINT_DRIFT_BYPASS=1` for every commit on a new AC** — defeats drift detection. Better: amend first, then commit normally.
- **Closing an AC before the work is committed** — `acs_closed_ids` records intent, not done. Combined with `state.gates_passed` it forms the verify-phase gate.
- **Closing an AC without inject-catch-restore proof** — file presence ≠ Production. See [`USAGE.md` §"Inject-violation-catch-restore methodology"](../USAGE.md#inject-violation-catch-restore-methodology).

---

## Closing an AC at Production verdict

```bash
# 1. Build/wire the capability
# 2. Create violation fixture if new gate type:
$EDITOR scripts/violation-fixtures/<name>.patch

# 3. Run inject-catch-restore helper
PROOF_FILE=docs/sprints/<slug>/proof/AC-N.md \
AC_ID=AC-N \
GATE_NAME="<gate name>" \
ASSERT_PATTERN="<substring expected in caught output>" \
  bash scripts/sprint-inject-violation.sh <fixture-name> "<gate command>"

# 4. Verify proof file
cat docs/sprints/<slug>/proof/AC-N.md

# 5. Mark AC closed
AMEND_WHY="AC-N gate proven via inject-catch-restore" \
AMEND_INTENT="Move to acs_closed_ids; production verdict logged in proof file" \
  bash scripts/sprint-amend-spec.sh --close-ac AC-N

# 6. Update readiness report
node scripts/sprint-harness-readiness.mjs <slug>
```
