---
name: git-best-practices
description: Enforce conventional commits, cog usage, and clean git hygiene when committing, tagging, or preparing releases
---

## Commit messages

- Follow Conventional Commits: `<type>[scope]: <description>`
- Valid types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `ci`
- Subject line: imperative mood, no period, max 72 chars
- Breaking changes: append `!` after type or add `BREAKING CHANGE:` footer

## Cocogitto (cog)

- Install the commit-msg hook locally: `cog install-hook commit-msg`
- Validate history since last tag: `cog check --from-latest-tag`
- Generate changelog: `cog changelog`
- Bump version and tag: `cog bump --auto`
- After `cog bump`, verify the tag was created before pushing: `git tag`

## Tagging

- Always tag after `init.sh` is run on a new repo so `cog check --from-latest-tag` has a reference point
- Use annotated tags: `git tag -a v0.1.0 -m "v0.1.0"`

## General hygiene

- One logical change per commit; do not mix refactors with features
- Never amend pushed commits
- Keep the working tree clean before running `make tests`
