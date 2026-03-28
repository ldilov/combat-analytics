# Harness Forge Shared Runtime

This workspace uses `.hforge/` as the hidden AI layer for Harness Forge.
`.hforge/runtime/` is the shared intelligence runtime, while `.hforge/library/` and `.hforge/templates/` hold the canonical hidden operating content.

## Runtime Version
- schema version: `3`
- package version: `1.1.1`
- initialized at: `2026-03-28T19:46:59.710Z`
- generated at: `2026-03-28T19:53:14.859Z`

## Visibility Policy
- mode: `hidden-ai-layer`
- hidden canonical: `.hforge/generated`
- hidden canonical: `.hforge/library/knowledge`
- hidden canonical: `.hforge/library/rules`
- hidden canonical: `.hforge/library/skills`
- hidden canonical: `.hforge/runtime`
- hidden canonical: `.hforge/state`
- hidden canonical: `.hforge/templates`
- visible bridge: `.agents/skills`
- visible bridge: `.claude`
- visible bridge: `.specify`
- visible bridge: `AGENTS.md`
- visible bridge: `CLAUDE.md`

## Installed Targets
- `claude-code` (native) - Claude Code
  - instruction: `AGENTS.md`
  - instruction: `CLAUDE.md`
  - instruction: `.agents/skills`
  - instruction: `.claude/settings.json`
  - runtime: `.hforge/runtime/index.json`
  - runtime: `.hforge/runtime/README.md`
  - notes: Claude Code keeps repo-root and .claude bridges thin while canonical skills, rules, knowledge, and templates live under the hidden .hforge layer.

## Durable Surfaces
- `.hforge/runtime/decisions/` - Durable decision records and maintainership rationale.
- `.hforge/runtime/findings/` - Durable findings, risks, and evidence-backed observations.
- `.hforge/library/knowledge/` - Canonical hidden knowledge packs and examples.
- `.hforge/library/rules/` - Canonical hidden engineering rules and constraints.
- `.hforge/library/skills/` - Canonical hidden skill library for installed workspaces.
- `.hforge/runtime/recursive/` - Optional recursive session runtime for difficult work.
- `.hforge/runtime/repo/` - Structured repository understanding and architecture anchors.
- `.hforge/runtime/` - Shared runtime, task artifacts, and repo intelligence.
- `.hforge/runtime/tasks/` - Task packs, requirements, implementation notes, and review context.
- `.hforge/templates/` - Canonical hidden task and workflow templates.
- `.hforge/runtime/tasks/TASK-XXX/file-interest.json` - Task-aware ranked file context for an active task
- `.hforge/runtime/tasks/TASK-XXX/impact-analysis.json` - Derived impact analysis for an active task
- `.hforge/runtime/recursive/sessions/RS-XXX/session.json` - Optional recursive draft session with budget, handles, and promotion state
- `.hforge/runtime/recursive/sessions/RS-XXX/summary.json` - Deterministic recursive handoff summary for the session

## Short-Term Cache
- `.hforge/runtime/cache/` - Compact working-memory and resumability state for active work.

## Baseline Runtime Artifacts
- `.hforge/runtime/repo/instruction-plan.json` - Target-aware instruction bridge plans for installed runtimes. (source: hforge synthesize-instructions --json)
- `.hforge/runtime/repo/recommendations.json` - Evidence-backed bundle, profile, skill, and validation recommendations. (source: hforge recommend --json)
- `.hforge/runtime/repo/repo-map.json` - Structured repository map and boundary summary. (source: hforge cartograph --json)
- `.hforge/runtime/findings/risk-signals.json` - Detected risk signals that should influence runtime guidance. (source: hforge scan --json)
- `.hforge/runtime/repo/scan-summary.json` - Baseline repository scan signals and detected stack evidence. (source: hforge scan --json)
- `.hforge/runtime/repo/target-support.json` - Portable target support summary derived from the capability matrix. (source: hforge recommend --json)
- `.hforge/runtime/findings/validation-gaps.json` - Detected validation gaps that should influence runtime guidance. (source: hforge scan --json)

## Discovery Bridges
- `AGENTS.md` [claude-code, native] - Claude Code discovery surface
- `CLAUDE.md` [claude-code, native] - Claude Code discovery surface
- `.agents/skills` [claude-code, native] - Claude Code discovery surface
- `.claude/settings.json` [claude-code, native] - Claude Code discovery surface
- `.hforge/runtime/index.json` [claude-code, native] - Claude Code shared-runtime companion surface
- `.hforge/runtime/README.md` [claude-code, native] - Claude Code shared-runtime companion surface
