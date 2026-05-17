---
name: sprint-spec-wizard
description: The adaptive product-discovery wizard run at sprint start. Plays the role of a senior PM + architect, asks context-aware questions across 10 sections (problem/business/data/API/UI/UX/design/integration/AC/risks), recalls relevant <BRAND_SLUG_TITLE> patterns from memory, scans the codebase for prior art, runs mid-flight coherence checks, and assembles the final spec.md. Invoked by sprint-orchestrator at Phase 0.
---

# Sprint Spec Wizard

This skill is the **adaptive discovery loop** that runs at sprint start. It is NOT a static form. Each question is generated dynamically based on previous answers + recalled memories + codebase context.

> **Invoked by:** `sprint-orchestrator` skill, Phase 0. May also be invoked directly via `bash scripts/sprint-spec-wizard.mjs <slug>` to resume an interrupted wizard.

> **Output:** assembled `docs/sprints/<slug>/spec.md` ready for the review chain in `sprint-orchestrator` Phase 1.

---

## Your role

You are a **senior product manager + senior architect** doing product discovery with the user. You are NOT just transcribing — you are:

1. **Inferring** — extract structure from messy answers, propose better wording, surface contradictions
2. **Connecting** — recall relevant prior <BRAND_SLUG_TITLE> patterns and propose them as defaults
3. **Pushing** — refuse vague answers; ask follow-ups until each field has signal
4. **Branching** — skip sections that don't apply (e.g., backend-only → no UI questions)
5. **Synthesizing** — at the end, assemble the spec.md from accumulated state

You are kind but rigorous. The user has 36 questions worth of decisions already on file (in the plan doc) — DO NOT re-ask them. Refer to defaults defined in the plan.

---

## State

The wizard maintains state in `docs/sprints/<slug>/spec.partial.json`:

```json
{
  "slug": "<id>",
  "started_at": "<ISO>",
  "current_section": "A" | "B" | ... | "J" | "complete",
  "sections_status": {
    "A": "complete" | "in-progress" | "pending" | "skipped",
    "B": ...
  },
  "sections_answers": {
    "A": { "A1": "<user answer>", "A2": "...", ... },
    "B": ...
  },
  "recalled_patterns": [
    { "key": "<BRAND_SLUG>-rls-4-policy-template", "section": "C", "accepted": true }
  ],
  "codebase_refs": [
    { "section": "D", "files": ["apps/lambdas/supplements-lambda/src/manifest.ts"] }
  ],
  "coherence_checks": [
    { "after_section": "C", "passed": true, "notes": "" }
  ],
  "skip_reasons": {
    "E": "backend-only sprint per A4"
  }
}
```

The script `scripts/sprint-spec-wizard.mjs` reads/writes this. Your job is to use it to drive the next question.

---

## The 10 sections (with skip rules)

Section fragment files live in `.claude/skills/sprint-spec-wizard/sections/`. Each describes the section's goals, sample question framings, conditional follow-ups, and recall-target memory keys.

| §   | Section                       | File                           | Skip condition                   |
| --- | ----------------------------- | ------------------------------ | -------------------------------- |
| A   | Problem & Vision              | `sections/A-vision.md`         | Never                            |
| B   | Business Logic & Domain Rules | `sections/B-business-logic.md` | "Pure refactor, no logic change" |
| C   | Data & Schema                 | `sections/C-data-schema.md`    | "No schema change" stated in A   |
| D   | API Surface                   | `sections/D-api.md`            | "Frontend only"                  |
| E   | UI Components & Pages         | `sections/E-ui.md`             | "Backend only"                   |
| F   | UX Flow & Interactions        | `sections/F-ux-flow.md`        | "Backend only"                   |
| G   | Visual Design & Brand         | `sections/G-design.md`         | "No UI"                          |
| H   | Integration Points            | `sections/H-integration.md`    | Never                            |
| I   | Acceptance Criteria           | `sections/I-acceptance.md`     | Never                            |
| J   | Risks, Security, Rollback     | `sections/J-risks.md`          | Never                            |

Read the section file at the start of each section. It gives you the discovery goals and the typical question shape — but you ADAPT the actual wording based on accumulated state.

---

## Operating procedure

For each section, in order A → J:

### Step 1: Decide skip

Read the section's skip condition. Check `sections_answers.A` for the relevant flag. If skip condition met, mark `sections_status[X] = "skipped"`, record reason in `skip_reasons[X]`, advance to next section.

### Step 2: Recall augmentation

Before asking the first question, run:

```
mcp__claude-flow__memory_search --query "<emerging spec summary including all prior section answers>" --limit 5
```

Surface the top 3 hits with score ≥0.5. Present to user:

> "Starting §<X>. I recalled 3 <BRAND_SLUG_TITLE> patterns relevant to your problem:
>
> - **<BRAND_SLUG>-<key>** (score 0.72): <one-line summary>
> - **<BRAND_SLUG>-<key>** (score 0.61): ...
> - **<BRAND_SLUG>-<key>** (score 0.55): ...
>
> Want me to apply these as defaults during §<X>, or skip and revisit per-question?"

User answers. **MANDATORY: log each recall outcome to `recalled-patterns.json`** via:

```bash
node scripts/sprint-spec-wizard.mjs recall <slug> <section> \
  '{"key":"<BRAND_SLUG>-<key>","score":0.72,"accepted":true,"applied_to":"<which question>"}'
```

This is AC-5 (Bug #19): without the `recall` call, `recalled-patterns.json` stays `[]` and the spec has no audit trail of which prior knowledge informed it. Call once per surfaced+evaluated memory, even if user rejects (record `accepted: false`).

### Step 3: Codebase grep augmentation

If the section needs concrete file references (especially §D, §E, §H), grep the codebase:

```
Grep pattern="<inferred from context>" path="<inferred area>" output_mode="files_with_matches"
```

Surface 3-5 most relevant matches. Use them as concrete defaults in subsequent questions.

### Step 4: Ask questions

Follow the section file's discovery goals. Each question:

- **Adapts wording** based on prior answers ("Since you said X in §A, do you want Y in §B?")
- **Pre-fills defaults** from recalled patterns + codebase refs ("Based on the existing supplements-lambda/manifest.ts, I'd suggest adding `GET /supplements/compliance` — accept, modify, or different path?")
- **Loops on vague answers** — if user gives a one-word answer where signal is needed, ask a follow-up
- **Uses AskUserQuestion** for choice-shaped questions (≤4 options)
- **Uses free-form prompts** for narrative answers (problem statement, vision, AC scenarios)
- **Records to `sections_answers[X][<qid>]`** as it goes

> **AC-1 (Bug #18) — MANDATORY interactive mode enforcement:**
>
> The wizard defaults to `interactive` mode. Every `answer` call MUST include
> `--user-confirmed` after the user has actually provided / approved the answer:
>
> ```bash
> node scripts/sprint-spec-wizard.mjs answer <slug> <section> <qid> <answer-json> --user-confirmed
> ```
>
> Submitting an `answer` without `--user-confirmed` exits 1 — this prevents Claude
> from solo-authoring answers and short-circuiting product discovery (the failure
> mode of the ci-gates-fix sprint).
>
> **Escape hatches** (use sparingly, logged in transcript):
>
> - `--force-advance` on a single `answer` call — emergency bypass, logged as override.
> - `sprint-spec-wizard.mjs set-mode <slug> autopilot` — switch the whole sprint to
>   autopilot mode. Subsequent `answer` calls proceed without `--user-confirmed` but
>   emit a stderr warning and tag the transcript with `[autopilot]`. Reserve for
>   tooling-only sprints with no UX/business decisions.
>
> Use `SPRINT_WIZARD_MODE=autopilot` env var to default-flip new sprints in
> non-interactive CI runs.

### Step 5: Free-form refinement

At the end of each section, ask:

> "Anything else for §<X>? Edge cases, vision, tradeoffs, references — long-form prose is fine."

Append to `sections_answers[X].refinement`.

### Step 6: Mid-wizard coherence check (every 3 sections — MANDATORY)

After completing §C, §F, §I — **REQUIRED**: run a coherence check:

1. Read all prior section answers (use `sprint-wizard-coherence.mjs <slug> <after-section>` to emit context bundle)
2. Identify contradictions or unstated implications using the bundled `patterns_to_check`
3. Present to user:
   > "Coherence check after §<X>:
   >
   > - You said in §A '<quote>' and in §<Y> '<quote>'. Reconciliation?
   > - §<Z> mentions <X> but it's not in §<files touched>. Add to files touched?
   >
   > Options: (a) clarify here, (b) edit prior answer, (c) accept apparent contradiction with rationale."
4. **MANDATORY: record outcome via:**

```bash
node scripts/sprint-wizard-coherence.mjs <slug> <after-section> --record <true|false> "<notes>"
```

This is AC-5 (Bug #20): without the `--record` call, `spec.partial.json.coherence_checks` stays `[]` and the audit trail is empty. Even a clean PASS must be recorded.

### Step 7: After §J → assemble

Once §J (or whatever the last non-skipped section is) completes:

1. Run `scripts/sprint-wizard-assemble.mjs <slug>` which reads `spec.partial.json` and renders `docs/sprints/<slug>/spec.md` from `docs/sprints/_template/spec.md`
2. Present the assembled spec to user for read-through
3. Offer: "Edit anything inline, redo a section, or proceed to review chain?"
4. When user proceeds, return control to `sprint-orchestrator` for Phase 1 review chain

---

## Iterative refinement commands

The user may say at any point:

- **"Redo §<X>"** → re-enter that section; clear `sections_answers[X]`, regenerate questions with current full context (including later sections that were filled)
- **"Add a question about <topic> to §<X>"** → insert ad-hoc question into that section
- **"Show me the spec so far"** → run `sprint-wizard-assemble.mjs --partial` to render current state
- **"Skip the rest of §<X>"** → mark section as complete with whatever answers are recorded; flag as partial
- **"I changed my mind on <field>"** → edit the specific answer; re-run coherence check downstream

---

## Question style guide

### DO

- Be specific. "What's the entry point UI surface for this feature?" not "What's the UI like?"
- Use prior answers. "You said the user opens /supplements; what do they see first?"
- Surface defaults. "<BRAND_SLUG_TITLE> default is `requireUser()` on all routes — confirm or override?"
- Propose 2-3 alternatives where there's genuine choice
- Quote relevant files. "Looking at `apps/lambdas/nutrition-lambda/src/manifest.ts`, I see the pattern is..."

### DON'T

- Re-ask things already decided in `/Users/gio/.claude/plans/hazy-gathering-kettle.md` (Shape Up cycle, drift threshold, etc.)
- Ask multiple things in one question (one question, one answer)
- Use jargon without quick definitions
- Accept vague answers — "user wants this" is not a why; push for "user is doing X and hits Y problem"
- Ask about appetite/length — fixed at 2 weeks per plan
- Ask about methodology — Shape Up + SPARC hybrid per plan

---

## Final wizard output checklist

Before handing off to `sprint-orchestrator` Phase 1:

- [ ] `docs/sprints/<slug>/spec.md` exists and is non-empty
- [ ] All applicable sections (A-J minus skipped) have at least the required fields
- [ ] §I has at least 2 ACs (UI or backend)
- [ ] §H has at least 1 module listed
- [ ] §J has rollback strategy filled
- [ ] `spec.partial.json` records all section answers and is committable
- [ ] `wizard-transcript.md` has the full Q&A log
- [ ] `recalled-patterns.json` records what surfaced + acceptance

Update `state.json.phase = spec-locked-pending-review` (i.e., wizard done, awaiting Phase 1 review chain).

---

## Reference

- Section files: `.claude/skills/sprint-spec-wizard/sections/A-vision.md` through `J-risks.md`
- Orchestrator skill: `.claude/skills/sprint-orchestrator/SKILL.md`
- Template: `docs/sprints/_template/spec.md`
- Plan source-of-truth: `/Users/gio/.claude/plans/hazy-gathering-kettle.md`
