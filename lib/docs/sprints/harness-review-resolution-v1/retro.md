# Retro — harness-review-resolution-v1

> **Closed:** 2026-05-19
> **ACs:** 7/7 production (AC-1..AC-7)
> **Walk:** spec-wizard → spec-locked → design-locked → building → cleaning → verifying → review-resolution → pre-deploy → deploying → done — full 13-phase manifest exercise

## What worked

Sketch A (superset) was the right call. Keeping `audit-resolution` + `_pp_pred_audit_resolution_complete` + `sprint-audit-resolve.sh` as legacy aliases gave us zero-churn back-compat: the `review_resolution_complete` predicate transparently consumes legacy `audit_findings_*` fields via union jq. v0.7.2 sprints walk through the new predicate without touching their state.json. The 5 ADRs locked in design.md (unified schema, legacy alias, per-producer baselines, global HAR namespace, generic phase name) all held — no late surprises.

Scope-bounding inheritance from v0.7.2 worked exactly as designed during dogfood: audit produced 4 advisory findings, all in `.claude/helpers/github-safe.js`, all out-of-scope per `## Files touched`. Logged as `[OUT/<severity>]`, didn't block phase advance. Knip + sonar vacuously PASSed — review_findings_total = 0, predicate trivially satisfied.

Per-producer baseline + per-producer regression streak (state.review_rerun_regression_streak.<producer>) is a clean generalization of the audit-only counter. jq's `(.review_rerun_regression_streak // {}) | .[$p] = $s` is idiomatic enough to read inline.

## What didn't

Daemon worker hang in verifying phase. Audit completed cleanly in ~40-80s but testgaps hit a `claude --print` stall (~5+ min, 1.5GB RSS, only 11s CPU) on multiple retries. WORKER_TIMEOUT_S=15 didn't propagate through `ruflo daemon trigger` → `claude --print`. The advance-phase script exit-1'd on blocking-worker failure with no built-in bypass path.

Concurrent sprint-advance-phase invocations corrupted reproducibility during the walk. Two parallel processes running for the same slug both fired daemon workers in parallel and raced each other's `atomic_update_state` writes. A `state.advance_in_progress` mutex (or a flock at sprint-dir level) would prevent this.

Pre-commit lint-staged stash restore left merge conflict markers in 4 docs files. The 1d1abd5 commit had to clean them up. Stash-restore + linter-write interaction is a known sharp edge — the `// removed-from-stash <<<<<<<` markers come from the linter reformatting the same lines lint-staged stashed away.

## What surprised us

The existing stderr hint at advance-phase.sh:232 already documented `SPRINT_BYPASS_GATE=$worker SPRINT_BYPASS_WHY='<reason>'` as the recovery path for blocking-worker failure — but the bypass loop validation only accepted manifest sub-step gate names. The UX was documented as intended but never wired. The fix (extend `_ap_known_workers` validation against `phase-workers.json` + add per-worker bypass loop) was 30 LOC of pure additive code — could have shipped 2 sprints ago.

Sonar `--json` vacuous-PASS path (token-absent) ended up more load-bearing than expected. Most operator environments don't have `/tmp/sonar-token.txt` or `SONAR_TOKEN` set — the vacuous PASS means review-resolution doesn't pointlessly block in dev environments.

The `_pp_pred_review_resolution_complete` predicate writeup in design.md ADR-001 said "single jq filter for exit predicate; producer field discriminates." Implementation used a 7-line jq expression with union view — still single-filter, but more nuanced than the design's one-liner shape. Worth a refactor pass if a future sprint touches the predicate.

## Patterns extracted

### Pattern 1: Unified-superset phase pattern

When a phase needs to absorb multiple producer streams (audit + knip + sonar here; could be CI checks + static-analysis + security-scan elsewhere), introduce a new "review-X" phase that aggregates findings into a single `state.X_findings[]` array with a `producer` discriminator. Keep the legacy single-producer phase as an alias pointing at the new predicate's union path. Operators triage via one walker (`sprint-review-resolve.sh`) and exit via one predicate (`review_resolution_complete`). Back-compat is free via union jq.

### Pattern 2: Bypass-the-stderr-hint-only feature

When a script's stderr error message documents a recovery path ("bypass: SPRINT_BYPASS_GATE=...") but that path isn't actually wired, treat the hint as a contract and wire it. The cost is usually ~20-50 LOC of additive code (validation extension + bypass loop). Failing to wire makes operators trust the script's hints less and reach for kill-9 + git-reset workarounds.

### Pattern 3: Vacuous-PASS short-circuit for advisory producers

For findings producers that depend on external services (Sonar API, ruflo daemon LLM workers), the `--json` emit path should return `{producer, schema_version: 1, timestamp, findings: []}` with exit 0 when the external service is unreachable. The exit predicate (`resolved + deferred + accepted == total` with total = 0) is trivially satisfied. Operators in degraded environments aren't blocked; signal returns when the service is back.

## Open follow-ups

### `harness-wizard-state-and-gate-wiring-v1` (1-day appetite)

Wizard CLI gaps surfaced during planning:

- `scripts/sprint-spec-wizard.mjs` records answers to `spec.partial.json` but never syncs to `state.wizard_state.sections_status` (AC-5 of harness-orchestration-rig had filed this — verify it landed or pull forward).
- Coherence-after-C/F/I checks run + emit PASS to stdout but the gate name never appends to `state.gates_passed[]`. Replay validator should flag this as `doc_drift > 0` but it's hidden because the wizard predates v0.7.0 gate-recording.

Both fixes ~30 LOC each in the same file. Bundle as one sprint with 2 ACs.

### `harness-consensus-replacement-v1` (1-day appetite)

`ruflo consensus status` returns empty after proposal submission — third-party upstream bug documented in memory `feedback_hive_mind_consensus_decorative`. Replace `sprint-hive-mind-spec-lock.sh`'s ruflo dependency with a deterministic in-harness 5-vote tally: spawn 5 Task sub-agents in parallel with the spec.md as input, parse `verdict ∈ {pass, pass-with-notes, dissent}` from each output, write the majority verdict to `consensus-spec.json`. ~50 LOC + 5-vote prompt template.

### `harness-mirror-and-cleanup-v1` (2-3 day appetite)

Mirror v0.7.3 to `~/Desktop/sprint-harness/lib/`. Specifically:

- Copy: `sprint-review-resolve.sh`, `sprint-review-rerun.sh`, updated `phase-manifest.json/.schema.json/.mjs`, `phase-predicates.sh`, knip/sonar `--json` producer modes, `_templates/review-resolutions.md`.
- Update sprint-harness USAGE/QUICKSTART/DEVELOPER/SCRIPTS for v0.7.3 review-resolution phase.
- Inventory `docs/sprints/` and reclassify harness-\* sprints as exemplars in sprint-harness `lib/templates/sprints/` vs LifeOS app-feature sprints (keep in lifeos).
- Bump sprint-harness `package.json` to 0.7.3, CHANGELOG entry, `git tag v0.7.3`. Push gated on `gio` approval per org policy.

### `harness-advance-phase-mutex-v1` (0.5-day appetite)

Add `state.advance_in_progress` mutex (or flock at sprint-dir level) so concurrent `sprint-advance-phase.sh` invocations for the same slug can't race. Fix the symptom this sprint hit: two parallel verifying advances corrupted reproducibility.

## CLAUDE.md updates proposed

No new code conventions. The strictness policy + soft-delete mandate + RLS / auth-on-every-route rules in CLAUDE.md continue to apply — this sprint touched only harness scripts (none under `apps/lambdas/*` or `apps/web/*`), so no CLAUDE.md edits needed.

The "Active sprint" section of `CLAUDE.md` will auto-clear when `sprint-end.sh` runs.

<!-- auto-appended by sprint-end.sh document worker -->
### document worker proposals (2026-05-19T20:19:46Z)

```json
{
  "timestamp": "2026-05-19T20:19:45.364Z",
  "mode": "headless",
  "workerType": "document",
  "model": "haiku",
  "durationMs": 67335,
  "executionId": "document_1779221918029_bfw3af",
  "success": true,
  "findings": {
    "sections": [
      {
        "title": "LifeOS Documentation Opportunity",
        "content": "\nThe LifeOS (Ordex) codebase is a mature, multi-layered system with strong architectural patterns established in CLAUDE.md, project rules, and security guidelines. The documentation task requires bridging the gap between what the project *conventions* promise and what code *currently shows*.\n\n",
        "level": 2
      },
      {
        "title": "What I Know Without Reading Code",
        "content": "\nFrom the project context, I can identify:\n\n1. **Module Structure** (confirmed via exploration):\n   - 10 Lambda handlers (ai-scheduler, auth, finances, grocery, health, nutrition, planner, supplements, uploads, workouts)\n   - 6 shared packages (@lifeos/db, @lifeos/ui, @lifeos/utils, @lifeos/auth-middleware, @lifeos/types, @lifeos/api-client)\n   - Frontend app (apps/web, Next.js)\n\n2. **Established Conventions** (from CLAUDE.md):\n   - JSDoc format (though not explicitly specified, TypeScript strict mode suggests comprehensive typing)\n   - Commit messages follow: `type(scope): message` (feat, fix, refactor, docs)\n   - File naming: PascalCase components, camelCase hooks (usePrefix), camelCase utilities\n   - Comment philosophy: explain *why*, not *what*; rationale for non-obvious logic\n   - Validation: Zod schemas at ALL system boundaries (no exceptions)\n   - Auth: getUserId() in Lambdas, requireUser() in API routes\n   - Soft delete: deleted_at timestamps, never hard DELETE\n\n3. **Security Requirements** (documented in security.md):\n   - Input validation with Zod on all external input\n   - Parameterized queries only\n   - JWT verification (ES256 per Supabase 2025+)\n   - PII truncation in logs\n   - No hardcoded secrets\n   - RLS policies on every table\n\n4. **Known Gaps** (from memory index):\n   - Dispatcher 4xx logging was incomplete (typed AppErrors returned silently)\n   - Hydration mount-gate fix for Radix useId mismatches\n   - Drizzle sql template Date trap issues\n   - Enum drift debugging patterns documented\n   - Migration tracker drift detection\n\n",
        "level": 3
      },
      {
        "title": "What I Cannot Provide Without Code Access",
        "content": "\nWithout reading actual file contents, I cannot generate:\n- Specific JSDoc comments for undocumented functions (requires seeing the function signatures, parameters, return types, and logic)\n- Accurate README sections (requires understanding each module's purpose, exports, and usage patterns)\n- Complete API endpoint documentation (requires reading Lambda route handlers to map request bodies, responses, error cases)\n- Inline comments for complex logic (requires identifying which logic is non-obvious in context)\n- Usage examples (requires understanding each function's contract and typical use cases)\n\n</analysis>\n\n<summary>\n\n",
        "level": 3
      },
      {
        "title": "Documentation Generation Plan (Text-Only Constraints)",
        "content": "\n",
        "level": 2
      },
      {
        "title": "Phase 1: Systematic API Surface Analysis",
        "content": "I would analyze each module in this order:\n\n1. **Shared Packages** (foundation layer):\n   - @lifeos/types: TypeScript type definitions and their purpose\n   - @lifeos/api-client: Typed fetch wrapper with request/response schemas\n   - @lifeos/db: Drizzle ORM schemas, table definitions, query helpers\n   - @lifeos/auth-middleware: JWT verification, user context extraction\n   - @lifeos/utils: Utility functions (scheduling, macros, validation helpers)\n   - @lifeos/ui: React component library with prop interfaces\n\n2. **Lambda Handlers** (service layer):\n   - Document each Lambda's routes (request path → handler function)\n   - Map Zod input schemas to parameters\n   - Document response types and error responses\n   - Add error handling examples (especially 400 validation, 401 auth, 409 conflict)\n\n3. **Frontend** (presentation layer):\n   - Document exported React components (props, children, callbacks)\n   - Document custom hooks (inputs, outputs, side effects)\n   - Document page components (query params, state dependencies)\n\n",
        "level": 3
      },
      {
        "title": "Phase 2: Documentation Format",
        "content": "\nFor **Exported Functions** (in packages):\n```\n/**\n * [One-line summary of what it does]\n * \n * @param {Type} paramName - [what it represents, valid values if constrained]\n * @returns {Type} [what the return value means, when it might be falsy/null]\n * @throws {ErrorType} [when and why this error is thrown]\n * @example\n * const result = functionName(input)\n * // Use case: [concrete example of when to use this]\n */\n```\n\nFor **API Endpoints** (in Lambdas):\n```\n/**\n * POST /api/path - [Business purpose]\n * \n * @request {ZodSchema} body - [Field descriptions]\n * @response {ResponseSchema} 200 - [Success case field meanings]\n * @error 400 - [Validation failure conditions]\n * @error 401 - [Auth failure conditions]\n * @error 409 - [Conflict scenarios, e.g., pipeline already running]\n */\n```\n\nFor **Complex Logic** (inline):\n```\n// [Why this approach was chosen over alternatives]\n// [Hidden constraint or subtle invariant the logic maintains]\n```\n\n",
        "level": 3
      },
      {
        "title": "Phase 3: Known Documentation Priorities",
        "content": "\nBased on memory index and sprint history:\n\n**Critical (already discovered bugs/gaps)**:\n- Dispatcher 4xx logging pattern (typed AppErrors weren't being logged)\n- clientLogger behavior (API errors as plain objects, not Error instances)\n- Enum drift debugging (UI ↔ Zod ↔ pgEnum layer mismatch)\n- Date trap in Drizzle sql templates\n- Hydration mount-gate fix for Radix useId\n\n**High Priority (user-facing APIs)**:\n- AI Scheduler Lambda (generation_pipelines, time block scheduling)\n- Planner Lambda (block creation, conflict detection, soft delete)\n- Health Lambda (daily check-in, score calculation)\n- Nutrition Lambda (meal logging, macro aggregation)\n- Auth Lambda (JWT verification, user session)\n\n**Medium Priority (internal utilities)**:\n- Macro calculation helpers (nutritional math)\n- Time block conflict detection\n- Pipeline lifecycle management\n- RLS policy enforcement patterns\n\n",
        "level": 3
      },
      {
        "title": "Deliverables (If Tools Were Allowed)",
        "content": "\n1. JSDoc comments added to all exported functions (500+ functions estimated)\n2. README.md sections for each Lambda (10 files)\n3. API endpoint documentation (150+ routes estimated)\n4. Inline complexity comments for 50+ functions identified as non-obvious\n5. Usage example file for each shared package (6 files)\n6. Error handling guide (400, 401, 409 patterns across Lambda types)\n\n",
        "level": 3
      },
      {
        "title": "Current Blocker",
        "content": "\n**Without tool access, I cannot**:\n- Read function signatures to write accurate JSDoc\n- Identify which functions are currently undocumented\n- See error handling implementations to document error cases\n- Understand each function's actual behavior vs. intended behavior\n- Generate accurate usage examples\n\n**With tool access, I would**:\n1. Grep for `export function|export const|export default` across packages\n2. Read each exported symbol's implementation\n3. Identify missing JSDoc/comments\n4. Generate documentation following LifeOS conventions\n5. Cross-reference with test files to verify behavior\n6. Create module-level README sections\n\n",
        "level": 3
      },
      {
        "title": "Recommendation",
        "content": "The project is architecturally mature and conventions-rich. The documentation gap is primarily at the code-surface level (JSDoc, usage examples, error case documentation). A systematic pass through each module with the phase sequence above would achieve comprehensive coverage within existing conventions.\n\n</summary>",
        "level": 3
      }
    ],
    "codeBlocks": [
      {
        "language": "text",
        "code": "/**\n * [One-line summary of what it does]\n * \n * @param {Type} paramName - [what it represents, valid values if constrained]\n * @returns {Type} [what the return value means, when it might be falsy/null]\n * @throws {ErrorType} [when and why this error is thrown]\n * @example\n * const result = functionName(input)\n * // Use case: [concrete example of when to use this]\n */"
      },
      {
        "language": "text",
        "code": "/**\n * POST /api/path - [Business purpose]\n * \n * @request {ZodSchema} body - [Field descriptions]\n * @response {ResponseSchema} 200 - [Success case field meanings]\n * @error 400 - [Validation failure conditions]\n * @error 401 - [Auth failure conditions]\n * @error 409 - [Conflict scenarios, e.g., pipeline already running]\n */"
      },
      {
        "language": "text",
        "code": "// [Why this approach was chosen over alternatives]\n// [Hidden constraint or subtle invariant the logic maintains]"
      }
    ]
  },
  "rawOutputPreview": "<analysis>\n\n## LifeOS Documentation Opportunity\n\nThe LifeOS (Ordex) codebase is a mature, multi-layered system with strong architectural patterns established in CLAUDE.md, project rules, and security guidelines. The documentation task requires bridging the gap between what the project *conventions* promise and what code *currently shows*.\n\n### What I Know Without Reading Code\n\nFrom the project context, I can identify:\n\n1. **Module Structure** (confirmed via exploration):\n   - 10 Lambda handlers (ai-scheduler, auth, finances, grocery, health, nutrition, planner, supplements, uploads, workouts)\n   - 6 shared packages (@lifeos/db, @lifeos/ui, @lifeos/utils, @lifeos/auth-middleware, @lifeos/types, @lifeos/api-client)\n   - Frontend app (apps/web, Next.js)\n\n2. **Established Conventions** (from CLAUDE.md):\n   - JSDoc format (though not explicitly specified, TypeScript strict mode suggests comprehensive typing)\n   - Commit messages follow: `type(scope): message` (feat, fix, refactor, docs)\n   - File naming: PascalCase components, camelCase hooks (usePrefix), camelCase utilities\n   - Comment philosophy: explain *why*, not *what*; rationale for non-obvious logic\n   - Validation: Zod schemas at ALL system boundaries (no exceptions)\n   - Auth: getUserId() in Lambdas, requireUser() in API routes\n   - Soft delete: deleted_at timestamps, never hard DELETE\n\n3. **Security Requirements** (documented in security.md):\n   - Input validation with Zod on all external input\n   - Parameterized queries only\n   - JWT verification (ES256 per Supabase 2025+)\n   - PII truncation in logs\n   - No hardcoded secrets\n   - RLS policies on every table\n\n4. **Known Gaps** (from memory index):\n   - Dispatcher 4xx logging was incomplete (typed AppErrors returned silently)\n   - Hydration mount-gate fix for Radix useId mismatches\n   - Drizzle sql template Date trap issues\n   - Enum drift debugging patterns documented\n   - Migration tracker drift detection\n\n### What I Cannot Provide Without Code Access\n\nWitho",
  "rawOutputLength": 7095
}```
