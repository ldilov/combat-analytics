# Skills

Harness Forge ships four major skill families.

## Discovery model

- `.agents/skills/` wrappers are the lightweight discovery layer for supported agent runtimes
- `.hforge/library/skills/` directories are the canonical execution layer
- `references/` directories hold deeper runtime-facing guidance
- `.hforge/library/docs/authoring/enhanced-skill-import.md` preserves maintainer-facing provenance for imported upgrades

## Seeded language skills

- `.hforge/library/skills/typescript-engineering/`
- `.hforge/library/skills/java-engineering/`
- `.hforge/library/skills/dotnet-engineering/`
- `.hforge/library/skills/lua-engineering/`
- `.hforge/library/skills/powershell-engineering/`

## Structured language skills

- `.hforge/library/skills/python-engineering/`
- `.hforge/library/skills/go-engineering/`
- `.hforge/library/skills/kotlin-engineering/`
- `.hforge/library/skills/rust-engineering/`
- `.hforge/library/skills/cpp-engineering/`
- `.hforge/library/skills/php-engineering/`
- `.hforge/library/skills/perl-engineering/`
- `.hforge/library/skills/swift-engineering/`
- `.hforge/library/skills/shell-engineering/`

Several of these language skills now also ship supplemental `references/`
packs so agents can pull repo-exploration, debugging, output-template, and
ecosystem heuristics without leaving the project package.

The March 2026 enhanced-skills import also deepened the TypeScript, .NET, Lua,
and JavaScript packs with additional runtime-boundary, packaging, onboarding,
and modernization guidance sourced into project-owned `references/` directories.

## Workflow orchestration skills

- `.hforge/library/skills/speckit-analyze/`
- `.hforge/library/skills/speckit-checklist/`
- `.hforge/library/skills/speckit-clarify/`
- `.hforge/library/skills/speckit-constitution/`
- `.hforge/library/skills/speckit-implement/`
- `.hforge/library/skills/speckit-plan/`
- `.hforge/library/skills/speckit-specify/`
- `.hforge/library/skills/speckit-tasks/`
- `.hforge/library/skills/speckit-taskstoissues/`

## Operational helper skills

- `.hforge/library/skills/engineering-assistant/`
- `.hforge/library/skills/repo-onboarding/`
- `.hforge/library/skills/documentation-lookup/`
- `.hforge/library/skills/security-scan/`
- `.hforge/library/skills/release-readiness/`
- `.hforge/library/skills/architecture-decision-records/`

## Workload-specialized skills

- `.hforge/library/skills/incident-triage/`
- `.hforge/library/skills/dependency-upgrade-safety/`
- `.hforge/library/skills/performance-profiling/`
- `.hforge/library/skills/test-strategy-and-coverage/`
- `.hforge/library/skills/api-contract-review/`
- `.hforge/library/skills/db-migration-review/`
- `.hforge/library/skills/pr-triage-and-summary/`
- `.hforge/library/skills/observability-setup/`
- `.hforge/library/skills/parallel-worktree-supervisor/`
- `.hforge/library/skills/repo-modernization/`
- `.hforge/library/skills/cloud-architect/`

## Supplemental engineering reference skills

- `.hforge/library/skills/javascript-engineering/`

## Depth expectations

Operational and workload skills should expose:

- trigger signals
- the repo surfaces to inspect first
- a stable output contract
- clear failure modes
- escalation behavior

Imported upgrades should also keep an auditable inventory record and preserve
maintainer-facing provenance instead of shipping duplicate skill identities.

Single-skill ports such as `engineering-assistant` should preserve the same
discipline through `.hforge/library/manifests/catalog/engineering-assistant-import-inventory.json`
and `.hforge/library/docs/authoring/engineering-assistant-port.md`.
