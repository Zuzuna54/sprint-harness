# OpenCode Usage Guide

> Sprint Harness v0.7.3+ supports both Claude Code and OpenCode runtimes.

---

## Installation for OpenCode

```bash
npx @ordex/sprint-harness install
```

During installation, the installer will detect available runtimes and ask which one to target:

```
Multiple runtimes detected. Which one should this harness target?
  - claude-code
  - opencode

Install for opencode? (default: claude-code)
```

Select `opencode` to install OpenCode-specific configuration.

---

## What Gets Installed for OpenCode

| Component | Claude Code | OpenCode |
|-----------|-------------|----------|
| Skills | `.claude/skills/` | `.claude/skills/` + `.opencode/skills/` |
| Agents | `.claude/agents/` | `.claude/agents/` + `.opencode/agents/` |
| Hooks | `.claude/settings.json` | `.claude/settings.json` + `.opencode/hooks.json` |
| MCP | `.mcp.json` (ruflo) | `opencode.json` (opencode-orchestrator) |
| Config | `settings.json` | `settings.json` + `opencode.json` |

---

## OpenCode-Specific Configuration

### opencode.json

The main OpenCode configuration includes:

```json
{
  "plugin": ["opencode-claude-hooks"],
  "mcp": {
    "opencode-orchestrator": {
      "type": "local",
      "command": ["npx", "-y", "opencode-orchestrator@latest", "mcp", "start"]
    }
  }
}
```

### Hooks Compatibility

The `opencode-claude-hooks` plugin reads `.claude/settings.json` hooks and fires them in OpenCode. This provides ~80% compatibility with Claude Code hooks.

**Supported hooks:**
- PreToolUse (Bash, Edit, Write, MultiEdit)
- PostToolUse
- SessionStart
- SessionEnd
- Stop

**Exit codes:**
- `0` = Allow
- `2` = Block

---

## MCP Tool Names

| Feature | Claude Code (ruflo) | OpenCode (opencode-orchestrator) |
|---------|---------------------|----------------------------------|
| Swarm | `mcp__claude-flow__swarm_init` | `mcp__opencode-orchestrator__swarm_init` |
| Memory | `mcp__claude-flow__memory_search` | `mcp__opencode-orchestrator__memory_search` |
| Claims | `mcp__claude-flow__claims_claim` | `mcp__opencode-orchestrator__claims_claim` |
| Hive-mind | `mcp__claude-flow__hive-mind_init` | `mcp__opencode-orchestrator__hive_mind_init` |

**Note:** The sprint-harness skills reference `mcp__claude-flow__*` tools. For full OpenCode compatibility, either:
1. Use opencode-orchestrator which supports similar tool names
2. Update skill references to use opencode-orchestrator tool names

---

## Environment Variables

| Variable | Values | Description |
|----------|--------|-------------|
| `SPRINT_RUNTIME` | `claude-code` \| `opencode` | Runtime detection (set by installer) |
| `OPENCODE_DISABLE_CLAUDE_CODE_HOOKS` | `1` | Disable Claude Code hook compatibility |

---

## Known Differences from Claude Code

1. **Agent format** — OpenCode agents use similar markdown format but with some frontmatter differences
2. **Skills** — Auto-discovered from both `.claude/skills/` and `.opencode/skills/`
3. **Commands** — OpenCode uses `.opencode/commands/` instead of `.claude/commands/`
4. **Daemon workers** — OpenCode uses opencode-orchestrator daemon instead of ruflo daemon
5. **Metrics directory** — `.opencode-flow/metrics/` instead of `.claude-flow/metrics/`

---

## Troubleshooting

### Hooks not firing

Ensure `opencode-claude-hooks` plugin is in your `opencode.json`:

```json
{
  "plugin": ["opencode-claude-hooks"]
}
```

### MCP tools not available

Verify opencode-orchestrator is running:

```bash
opencode-orchestrator daemon status
```

### Skills not discovered

Check both locations:
- `.claude/skills/<name>/SKILL.md`
- `.opencode/skills/<name>/SKILL.md`

---

## Quick Reference

| Task | Claude Code | OpenCode |
|------|-------------|----------|
| Start sprint | `bash scripts/sprint-start.sh <slug>` | Same |
| Check status | `bash scripts/sprint-status.sh` | Same |
| Run wizard | `node scripts/sprint-wizard-assemble.mjs <slug>` | Same |
| Drift check | `bash scripts/sprint-drift-check.sh` | Same |

All shell scripts work identically in both runtimes.