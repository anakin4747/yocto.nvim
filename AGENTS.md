# Skills

| Situation | Skill |
|---|---|
| Committing, tagging, releasing, or generating a changelog | `.agents/skills/git-best-practices` |
| Reviewing a diff or PR | `.agents/skills/code-review` |
| Adding a feature or fixing a bug | `.agents/skills/tdd` |

# Running Tests

Always run tests as:

```sh
make
```

which runs them through docker with plenary patched in the rootfs. This is
important because the tests rely on plenary being available in the runtime
environment.

## Performant Tests

All tests shall avoid syscalls at all cost to avoid slowing down the tests.
This goes the same for anything that could slow down the tests. A short
iteration cycle is important for faster iteration with AI agents.
