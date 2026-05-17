# state.json recovery

`docs/sprints/<slug>/state.json` is the source of truth for sprint state. When it's corrupted or in a wrong shape, recover with one of these recipes.

---

## How corruption happens

Concurrent writes from multiple sources:

- Husky post-commit hook (`reuse_audits` append)
- Sprint-end script (`pair_prompts`, `gate_bypasses`)
- Ruflo daemon workers (auto-progress phase, consolidation)
- Manual `jq` from CLI sessions
- Background tasks fired by Claude sessions

Symptoms:

- `node -e "JSON.parse(require('fs').readFileSync('...state.json'))"` throws `Unexpected non-whitespace character after JSON`
- Lines after `}` contain `},` and partial entries
- `sprint-status.sh` returns empty / silent fail
- pre-commit hook fails with `jq: parse error`

**Fixed in `c809568`** by adding STATE_LOCK around all writes in `.husky/post-commit`. If you see corruption again, look for new writers that don't use the lock.

---

## Recipe 1 — Restore from last git commit (most common)

```bash
git checkout HEAD -- docs/sprints/<slug>/state.json
node -e "JSON.parse(require('fs').readFileSync('docs/sprints/<slug>/state.json'))" && echo "✓ valid"
```

Loses any in-flight updates since last commit. Almost always the right call.

---

## Recipe 2 — Restore from baseline embedding archive

If you have `.baseline-embedding.day0.json`, the spec-hash and graph-hash tell you when state was last good:

```bash
node -e "
  const b = require('./docs/sprints/<slug>/.baseline-embedding.json');
  console.log('Baseline written:', b.embedded_at, 'spec_hash:', b.spec_hash.slice(0,12));
"
```

If state.json mtime is newer than baseline embedding, restore from git and re-run drift baseline:

```bash
git checkout HEAD -- docs/sprints/<slug>/state.json
bash scripts/sprint-rebaseline.sh <slug>
```

---

## Recipe 3 — Surgically repair a known field

If only one array field is broken (e.g., `gate_bypasses[]` has dangling `}`), you can extract the valid prefix:

```bash
# Identify the line number where the JSON breaks
node -e "
  const t = require('fs').readFileSync('docs/sprints/<slug>/state.json', 'utf8');
  try { JSON.parse(t); console.log('valid'); }
  catch(e) {
    const m = e.message.match(/position (\d+)/);
    const pos = parseInt(m[1]);
    console.log('breaks at position', pos, 'line', t.slice(0, pos).split('\n').length);
    console.log('--- context: ---');
    console.log(t.slice(Math.max(0, pos-200), pos+100));
  }
"
```

Then edit the file with your favorite editor to remove the broken trailing block. Validate with `node -e "JSON.parse(...)"` after each edit.

---

## Recipe 4 — Rebuild state.json from spec.md (last resort)

If state.json is irrecoverable, regenerate the essentials from the locked spec:

```bash
SLUG=<slug>
SPEC="docs/sprints/$SLUG/spec.md"
STARTED="$(grep -oE '## Status[\s\S]*?started.+\d{4}' $SPEC | head -1)"

cat > docs/sprints/$SLUG/state.json <<JSON
{
  "slug": "$SLUG",
  "phase": "building",
  "started_at": "<copy from spec.md ## Status section>",
  "started_at_epoch": $(date +%s),
  "day": 0,
  "appetite_days": 14,
  "appetite_seconds": 1209600,
  "gates_passed": ["spec-lock"],
  "acs_total": $(grep -cE '\*\*AC-[0-9]+\*\*' $SPEC),
  "acs_closed": 0,
  "acs_closed_ids": [],
  "acs_in_progress": [],
  "drift_events": [],
  "pause_events": [],
  "scope_amendments": [],
  "files_touched": [],
  "wizard_state": { "current_section": "complete" },
  "git_branch": "sprint/$SLUG",
  "prev_phase": null,
  "closed_at": null
}
JSON
```

Then manually `--close-ac` for each AC you've already closed (check `git log` for `feat(<slug>/AC-N):` commits).

---

## Recipe 5 — Lock files left behind

If you see `state.json.lock` or `.reuse-audit.lock` files lingering:

```bash
# Check the held PID
cat docs/sprints/<slug>/state.json.lock 2>/dev/null
cat docs/sprints/<slug>/.reuse-audit.lock 2>/dev/null

# If process is dead, reclaim
PID=$(cat docs/sprints/<slug>/.reuse-audit.lock)
kill -0 $PID 2>/dev/null && echo "still alive" || rm docs/sprints/<slug>/.reuse-audit.lock
```

The post-commit hook auto-reclaims stale locks older than 30s, but manual cleanup is fine.

---

## Recipe 6 — Phantom sprint reasserts itself as active

If `sprint-status.sh` returns a sprint you thought was done:

```bash
# Find all non-done sprints
for s in docs/sprints/*/state.json; do
  slug=$(basename $(dirname $s))
  phase=$(node -e "console.log(require('./$s').phase)" 2>/dev/null)
  echo "$slug: $phase"
done

# Force the phantom to done
tmp=$(mktemp)
jq '.phase = "done" | .closed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'" | .abandoned_permanent = true' \
  docs/sprints/<phantom>/state.json > "$tmp" && mv "$tmp" docs/sprints/<phantom>/state.json
```

If it un-dones itself within minutes, a background daemon worker is racing you — kill ruflo daemon, mark done, restart.

---

## Prevention

- **Use `sprint-amend-spec.sh` for state mutations**, not raw `jq`. The script uses the shared lock.
- **Add to scope before editing**: run `--add-file` (with `AMEND_WHY`+`AMEND_INTENT`) BEFORE the Edit tool tries to touch a file.
- **Commit often** — every commit becomes a clean recovery point.
- **Avoid `git reset --hard`** during sprint work. Use `git revert` instead — preserves history.
