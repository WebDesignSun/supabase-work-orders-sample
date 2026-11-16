#!/bin/sh
# PreToolUse (Edit|Write|MultiEdit): CLAUDE.md says "an applied migration is
# immutable". A migration counts as applied once it is committed: from then on
# a preview database or a teammate may already have run it. Editing such a file
# is blocked (exit 2); the message tells Claude to add a new migration instead.
set -eu

file=$(jq -r '.tool_input.file_path // empty')

case "$file" in
  supabase/migrations/*.sql | */supabase/migrations/*.sql) ;;
  *) exit 0 ;;
esac

cd "${CLAUDE_PROJECT_DIR:-.}"
rel=${file#"$PWD"/}

if git cat-file -e "HEAD:$rel" 2>/dev/null; then
  echo "Blocked: $rel is already committed, and an applied migration is immutable (CLAUDE.md)." >&2
  echo "Change behaviour with a new file: supabase migration new <name>." >&2
  exit 2
fi
