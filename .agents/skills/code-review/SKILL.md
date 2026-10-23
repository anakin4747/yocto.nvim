---
name: code-review
description: Review code changes for correctness, style, test coverage, and Lua/Neovim plugin conventions
---

## Process

1. Read the diff in full before commenting
2. Understand intent before judging implementation
3. Distinguish blocking issues from suggestions — label them clearly

## What to check

**Correctness**
- Logic errors, off-by-one, nil handling in Lua
- Edge cases: empty buffers, missing files, invalid user input

**Neovim/Lua conventions**
- Prefer `vim.api.*` over deprecated vimscript interop where possible
- Avoid polluting global namespace; use module returns
- Autocommands should be in augroups with `clear = true`
- Keymaps should have `desc` set

**Tests**
- New behaviour must have a corresponding plenary test
- Tests must be independent; no shared mutable state between cases
- Assert specific values, not just truthiness

**Style**
- Consistent with existing code; do not reformat unrelated lines
- No trailing whitespace, no debug prints left in

## Output format

- List blocking issues first, then suggestions
- Quote the specific line when referencing code
- Keep comments short and actionable
