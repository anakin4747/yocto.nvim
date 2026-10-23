#!/usr/bin/env bash
set -e

if [[ "$(git remote -v)" == *"tmpl.nvim"* ]]; then
    echo "Error: this script must not be run inside the tmpl.nvim template repo" >&2
    exit 1
fi

read -r ORG NAME <<< "$(git remote -v | sed -nE '1s|.*github.com[:/]([^/]+)/(\S+) \(fetch\)|\1 \2|p')"

if [[ -z "$ORG" || -z "$NAME" ]]; then
    echo "Error: org and name must not be empty" >&2
    exit 1
fi

if [[ "$NAME" == *".git" ]]; then
    NAME="${NAME%.git}"
fi

if [[ "$NAME" == *".nvim" ]]; then
    NAME="${NAME%.nvim}"
fi

# Rename plugin/@NAME@.vim -> plugin/<name>.vim
git mv "plugin/@NAME@.lua" "plugin/${NAME}.lua"

# Rename tests/@NAME@_spec.lua -> tests/<name>_spec.lua
git mv "tests/@NAME@_spec.lua" "tests/${NAME}_spec.lua"

# Substitute placeholder tokens in affected files
FILES=(
    ".cqfdrc"
    "plugin/${NAME}.lua"
    "tests/minimal_init.lua"
    "tests/${NAME}_spec.lua"
    "cog.toml"
)

for f in "${FILES[@]}"; do
    sed -i \
        -e "s/@ORG@/${ORG}/g" \
        -e "s/@NAME@/${NAME}/g" \
        "$f"
done

# Stage substituted files
git add "${FILES[@]}"

git rm --force init.sh README.md

# Commit
git commit -m "chore: configure plugin as ${ORG}/${NAME}"

git tag "v0.1.0"
