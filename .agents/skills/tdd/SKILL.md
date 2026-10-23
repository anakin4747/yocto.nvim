---
name: tdd
description: Guide test-driven development using plenary.nvim busted-style tests for Neovim plugins
---

## Cycle

1. Write a failing test that describes the desired behaviour
2. Write the minimum code to make it pass
3. Refactor; keep tests green

## Test structure

- Files live in `tests/`, named `*_spec.lua`
- Use `describe` / `it` blocks; nest for context
- Each `it` block tests one behaviour
- Use `before_each` to set up, `after_each` to tear down — never share mutable state

## Assertions

- Prefer specific matchers: `assert.are.equal`, `assert.is_true`, `assert.is_nil`
- Avoid `assert.truthy` unless the value is genuinely boolean-intent
- For errors: `assert.has_error(fn, "expected message")`

## Running tests

```
make tests        # runs full suite inside cqfd container
```

## What belongs in a test

- Public API behaviour, not internal implementation details
- Edge cases: nil input, empty tables, missing files
- Error paths: assert the error message, not just that an error occurred

## What does not belong

- Tests that only pass because of global state leaking from a prior test
- Tests that call `vim.cmd` when `vim.api` suffices
- Commented-out tests
