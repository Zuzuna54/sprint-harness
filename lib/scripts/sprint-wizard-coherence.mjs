#!/usr/bin/env node
/**
 * sprint-wizard-coherence.mjs — Run a coherence check across accumulated answers.
 *
 * Called by Claude after every 3 sections (after §C, §F, §I) to detect
 * contradictions or unstated implications between sections.
 *
 * The actual reasoning is done by Claude — this script just:
 *   - assembles the accumulated state into a prompt-friendly format
 *   - prints prior answers grouped by section
 *   - prints known contradiction patterns to check
 *   - records the outcome to spec.partial.json
 *
 * Usage:
 *   sprint-wizard-coherence.mjs <slug> <after-section>
 *     → emit context bundle for Claude to do the check
 *
 *   sprint-wizard-coherence.mjs <slug> <after-section> --record <true|false> [notes]
 *     → record the outcome
 */

import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

const [, , slug, afterSection, flag, ...rest] = process.argv;

if (!slug || !afterSection) {
  console.error("Usage: sprint-wizard-coherence.mjs <slug> <after-section> [--record <true|false> [notes]]");
  process.exit(1);
}

const partialPath = join(REPO_ROOT, "docs", "sprints", slug, "spec.partial.json");
if (!existsSync(partialPath)) {
  console.error(`[!] spec.partial.json not found: ${partialPath}`);
  process.exit(1);
}

const partial = JSON.parse(readFileSync(partialPath, "utf8"));

// ── If recording, do that and exit ───────────────────────────────────────────
if (flag === "--record") {
  const passed = rest[0] === "true";
  const notes = rest.slice(1).join(" ");
  partial.coherence_checks ||= [];
  partial.coherence_checks.push({
    after_section: afterSection,
    passed,
    notes,
    at: new Date().toISOString(),
  });
  const { writeFileSync, appendFileSync } = await import("node:fs");
  writeFileSync(partialPath, JSON.stringify(partial, null, 2));
  appendFileSync(
    join(REPO_ROOT, "docs", "sprints", slug, "wizard-transcript.md"),
    `\n### Coherence check after §${afterSection} · ${passed ? "PASS" : "FAIL"}\n${notes || "(no notes)"}\n`
  );
  console.log(`Coherence check recorded: ${passed ? "PASS" : "FAIL"}`);
  process.exit(0);
}

// ── Otherwise, emit context bundle ───────────────────────────────────────────

const knownContradictionPatterns = {
  C: [
    {
      name: "Frontend-only but new schema",
      check: "If A.flags.frontend_only is true AND §C has new_tables → flag",
    },
    {
      name: "No schema change but B mentions new entities",
      check: "If A.flags.no_schema_change is true AND §B introduced new_entities → flag",
    },
    {
      name: "PII without encryption acknowledgment",
      check: "If §C.pii_touched is true AND encryption-at-rest not confirmed → flag",
    },
    {
      name: "Hard delete proposed",
      check: "If §C mentions DELETE policy with USING (true) → BLOCK (soft-delete rule)",
    },
  ],
  F: [
    {
      name: "Backend-only but UX flow filled",
      check: "If A.flags.backend_only AND §F has happy_path → flag",
    },
    {
      name: "Optimistic update but auth-required",
      check: "If §F mentions optimistic update on a mutation AND §D has auth-required → ensure rollback path",
    },
    {
      name: "Empty state forgotten",
      check: "If §E has list/grid component AND §F empty_states is unspecified → flag",
    },
  ],
  I: [
    {
      name: "AC count vs scope mismatch",
      check: "If §I has >5 ACs → propose sprint split",
    },
    {
      name: "Performance bars unrealistic",
      check: "If §I.performance bars deviate from LifeOS defaults without rationale → flag",
    },
    {
      name: "Files touched outside spec",
      check: "If §I.manual_qa mentions surfaces not in §E or §D → reconcile §H.files_touched",
    },
    {
      name: "Complex ACs missing for security-sensitive surface",
      check: "If §C.pii_touched AND §I has no complex:true ACs → flag (pair-mode missed)",
    },
  ],
};

const bundle = {
  slug,
  after_section: afterSection,
  accumulated_answers: partial.sections_answers || {},
  flags: partial.sections_answers?.A?.flags || {},
  patterns_to_check: knownContradictionPatterns[afterSection] || [],
  prior_coherence_checks: partial.coherence_checks || [],
  instructions_for_claude: [
    `Read all accumulated answers above.`,
    `Walk through each pattern_to_check; identify if it applies.`,
    `Find any contradictions not in the pattern list (unstated implications, vague answers that later sections rely on).`,
    `Present findings to user. Each finding offers: (a) clarify here, (b) edit prior answer, (c) accept apparent contradiction with rationale.`,
    `After user resolves, call: sprint-wizard-coherence.mjs ${slug} ${afterSection} --record <true|false> "<notes>"`,
  ],
};

console.log(JSON.stringify(bundle, null, 2));
