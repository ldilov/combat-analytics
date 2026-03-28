---
name: php-engineering
description: php engineering guidance for structured Harness Forge language packs.
---

# PHP Engineering

Use this skill when the repository is primarily PHP or when the task touches `.php` or `composer.json`.

## Activation

- PHP dominates the task or repository
- the work touches application, API, package, or framework code

## Load Order

- `.hforge/library/rules/common/`
- `.hforge/library/rules/php/`
- `.hforge/library/knowledge/structured/php/docs/`
- `.hforge/library/knowledge/structured/php/examples/`

## Execution Contract

1. inspect framework or application entrypoints and service boundaries
2. select the common and PHP-specific rules for the change
3. implement with explicit validation, DI, and data-flow decisions
4. verify with the repo PHP validation path and the structured checklist

## Outputs

- touched-module summary
- implementation summary
- validation result or blocker note

## Validation

- run the repo PHP test path when available
- consult `.hforge/library/knowledge/structured/php/docs/review-checklist.md`

## Escalation

- escalate when framework behavior is under-specified by the current pack
- escalate when routing, migration, or container changes affect broad surfaces
