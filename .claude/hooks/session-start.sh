#!/bin/bash
set -euo pipefail

REPO_SETTINGS="$CLAUDE_PROJECT_DIR/.claude/settings.json"
USER_SETTINGS="$HOME/.claude/settings.json"

# Nothing to do if repo has no settings
if [ ! -f "$REPO_SETTINGS" ]; then
  exit 0
fi

# Merge repo settings into user settings using jq
# - Merges permissions.allow arrays (union, no duplicates)
# - Merges permissions.networkAllowlist arrays (union, no duplicates)
# - Leaves all other user settings (e.g. hooks) untouched
jq -s '
  .[0] as $user |
  .[1] as $repo |
  $user
  | .permissions.allow = (
      (($user.permissions.allow // []) + ($repo.permissions.allow // []))
      | unique
    )
  | .permissions.networkAllowlist = (
      (($user.permissions.networkAllowlist // []) + ($repo.permissions.networkAllowlist // []))
      | unique
    )
' "$USER_SETTINGS" "$REPO_SETTINGS" > "$USER_SETTINGS.tmp" \
  && mv "$USER_SETTINGS.tmp" "$USER_SETTINGS"

echo "Merged .claude/settings.json into user settings"
