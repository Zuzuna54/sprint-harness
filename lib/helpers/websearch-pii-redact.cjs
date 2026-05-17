#!/usr/bin/env node
// PreToolUse:WebSearch hook — pipes the search query through
// scripts/sprint-pii-redact.sh before WebSearch fires.
//
// Hook protocol: reads JSON from stdin with shape:
//   { tool_input: { query: "..." } }
// Returns JSON to stdout. To modify the query, emit:
//   { decision: "allow", updatedInput: { query: "<redacted>" } }
// To block entirely, emit:
//   { decision: "block", reason: "..." }
//
// On unrecognized input (not a WebSearch call), returns empty allow → no-op.
"use strict";

const { execFileSync } = require("node:child_process");
const { join } = require("node:path");

const REPO_ROOT = process.env.CLAUDE_PROJECT_DIR || process.cwd();

let rawInput = "";
try {
  rawInput = require("node:fs").readFileSync(0, "utf8");
} catch {
  process.exit(0); // no stdin → silent no-op
}

let parsed = {};
try {
  parsed = JSON.parse(rawInput);
} catch {
  process.exit(0);
}

const query = parsed?.tool_input?.query;
if (typeof query !== "string" || query.length === 0) {
  process.exit(0);
}

let redacted = query;
try {
  redacted = execFileSync("bash", [join(REPO_ROOT, "scripts/sprint-pii-redact.sh"), query], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 2000,
  }).trim();
} catch {
  // Redactor failed — let original query through rather than blocking the user.
  process.exit(0);
}

if (redacted !== query) {
  // PII detected and stripped — return updated query.
  process.stdout.write(
    JSON.stringify({
      decision: "allow",
      updatedInput: { ...parsed.tool_input, query: redacted },
    }),
  );
} else {
  // No PII — let WebSearch fire as-is.
  process.exit(0);
}
