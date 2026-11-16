#!/bin/sh
# PostToolUse (Edit|Write|MultiEdit): keep every edit inside the CLAUDE.md checks.
# - *.ts: format with deno fmt, then deno lint; lint errors go back to Claude
#   (exit 2) so it fixes them before moving on.
# - migrations and pgTAP tests: remind Claude which checks the change needs.
set -eu
export NO_COLOR=1

file=$(jq -r '.tool_input.file_path // empty')
[ -n "$file" ] && [ -f "$file" ] || exit 0

cd "${CLAUDE_PROJECT_DIR:-.}"

context() {
  jq -n --arg msg "$1" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}'
}

case "$file" in
  *.ts)
    if ! out=$(deno fmt --quiet "$file" 2>&1 && deno lint --quiet "$file" 2>&1); then
      printf '%s\n' "$out" >&2
      exit 2
    fi
    ;;
  */supabase/migrations/*.sql)
    context "Migration changed. Run: supabase db reset && supabase test db. Then regenerate supabase/functions/_shared/database.types.ts (gen types + deno fmt, see CLAUDE.md) and add pgTAP tests for any new policy, raising plan(n) and the README test count."
    ;;
  */supabase/tests/*.sql)
    context "pgTAP test changed. Check that plan(n) matches the number of tests, run: supabase test db, and update the test count in README.md."
    ;;
esac
