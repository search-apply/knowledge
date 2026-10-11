#!/usr/bin/env bash
# scratch-wrap.sh: PreToolUse(Bash) hook. Reads the tool-call JSON on stdin; when the command is
# worth storing, rewrites it so its output lands in a temp file inside a brace group (not a
# subshell, so a cd in the original command still persists), captures the exit code, then hands
# the file to scratch-store.sh for storage over the line threshold and a digest in its place.
# Skips (no rewrite) a command that already contains scratch-store.sh, one with no command, or
# when KNOWLEDGE_SCRATCH=off. There is no length skip: a short command is exactly the kind worth
# storing. --self-test runs inline cases and needs no docker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$ROOT}"
# shellcheck source=./lib.sh
source "$CLAUDE_PLUGIN_ROOT/hooks/lib.sh"

should_skip() {
  local cmd="$1"
  [ -z "$cmd" ] && return 0
  case "$cmd" in *scratch-store.sh*) return 0 ;; esac
  [ "${KNOWLEDGE_SCRATCH:-on}" = "off" ] && return 0
  return 1
}

wrap_command() {
  local cmd="$1" session="$2" tmp store
  tmp=$(mktemp)
  # An EXIT trap, not a plain follow-on line: the original command may itself call `exit`
  # (for example `seq 1 100; exit 3`), which would otherwise end the whole wrapped script
  # before scratch-store.sh runs. A trap still fires on an explicit exit and captures its code.
  store=$(printf 'KNOWLEDGE_SESSION=%q "%s/hooks/scratch-store.sh" %q "$rc" %q' \
    "$session" "$CLAUDE_PLUGIN_ROOT" "$tmp" "$cmd")
  printf 'trap '\''rc=$?; %s; exit "$rc"'\'' EXIT\n{\n%s\n} > %q 2>&1' \
    "$store" "$cmd" "$tmp"
}

# process <json>: prints the hookSpecificOutput JSON on a rewrite, nothing on a skip.
process() {
  local input="$1" cmd session wrapped
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
  session=$(printf '%s' "$input" | jq -r '.session_id // empty')

  if should_skip "$cmd"; then
    return 0
  fi

  wrapped=$(wrap_command "$cmd" "$session")
  jq -cn --arg c "$wrapped" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:$c}}}'
}

self_test() {
  local fails=0 json cmd

  fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

  json='{"session_id":"s1","tool_input":{"command":"seq 1 100"}}'
  cmd=$(process "$json" | jq -r '.hookSpecificOutput.updatedInput.command // empty')
  [ -n "$cmd" ] || fail "rewrite" "no updatedInput.command for a plain command"
  printf '%s' "$cmd" | grep -qF '{' || fail "brace-group-open" "wrapped command is missing the opening brace"
  printf '%s' "$cmd" | grep -qF '} >' || fail "brace-group-close" "wrapped command is missing the closing brace redirect"
  printf '%s' "$cmd" | grep -qF 'rc=$?' || fail "exit-code-line" "wrapped command is missing the rc=\$? line"

  json='{"session_id":"s2","tool_input":{"command":"echo x; \"$CLAUDE_PLUGIN_ROOT/hooks/scratch-store.sh\" /tmp/x 0 y"}}'
  cmd=$(process "$json" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null || true)
  [ -z "$cmd" ] || fail "skip-already-wrapped" "rewrote a command that already contains scratch-store.sh"

  json='{"session_id":"s3","tool_input":{"command":"seq 1 100"}}'
  cmd=$(KNOWLEDGE_SCRATCH=off process "$json" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null || true)
  [ -z "$cmd" ] || fail "skip-scratch-off" "rewrote a command while KNOWLEDGE_SCRATCH=off"

  json='{"session_id":"s4","tool_input":{}}'
  cmd=$(process "$json" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null || true)
  [ -z "$cmd" ] || fail "skip-empty-command" "rewrote an empty command"

  if [ "$fails" -eq 0 ]; then
    echo "scratch-wrap: self-test ok"
    return 0
  fi
  return 1
}

main() {
  local input
  input=$(cat)
  process "$input"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi
main
