#!/usr/bin/env bash

# sample usage:
# ./publish_all_skills.sh 'other_skills/*/'

set -euo pipefail

pattern="${1:-skills/*/}"

shopt -s nullglob
dirs=( $pattern )

if [ ${#dirs[@]} -eq 0 ]; then
  echo "No directories matched: $pattern" >&2
  exit 1
fi

for d in "${dirs[@]}"; do
  python3 scripts/skill_registry.py publish --force "$d"
done