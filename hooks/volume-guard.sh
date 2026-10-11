#!/usr/bin/env bash
# volume-guard.sh: PreToolUse(Bash) guard.
# Blocks a command that would remove or prune the knowledge volume: `docker volume rm`,
# `docker rm -v` (a container removed with its volumes), `docker volume prune`, and
# `docker system prune --volumes`. Every other docker command, including a plain `docker ps`,
# passes. Exits 2 with a message on stderr naming the volume to block, 0 to allow.
# Reads the tool-call JSON on stdin; --self-test runs inline cases and needs no docker.
set -euo pipefail

# is_volume_rm: `docker volume rm|remove ...`
is_volume_rm() {
  printf '%s' "$1" | grep -qE '(^|[;&|[:space:]])docker[[:space:]]+volume[[:space:]]+(rm|remove)([[:space:]]|$)'
}

# is_rm_with_v: `docker rm ... -v ...` (removes a container's volumes too).
is_rm_with_v() {
  local cmd="$1"
  printf '%s' "$cmd" | grep -qE '(^|[;&|[:space:]])docker[[:space:]]+rm([[:space:]]|$)' || return 1
  printf '%s' "$cmd" | grep -qE '(^|[[:space:]])-[a-zA-Z]*v[a-zA-Z]*([[:space:]]|$)'
}

# is_volume_prune: `docker volume prune ...`
is_volume_prune() {
  printf '%s' "$1" | grep -qE '(^|[;&|[:space:]])docker[[:space:]]+volume[[:space:]]+prune([[:space:]]|$)'
}

# is_system_prune_volumes: `docker system prune ... --volumes ...`
is_system_prune_volumes() {
  local cmd="$1"
  printf '%s' "$cmd" | grep -qE '(^|[;&|[:space:]])docker[[:space:]]+system[[:space:]]+prune([[:space:]]|$)' || return 1
  printf '%s' "$cmd" | grep -qE '(^|[[:space:]])--volumes([[:space:]]|$)'
}

# decide: 0 allow, 2 block.
decide() {
  local cmd="$1" vol
  vol="${KNOWLEDGE_VOLUME:-knowledge_data}"
  if is_volume_rm "$cmd" || is_rm_with_v "$cmd" || is_volume_prune "$cmd" || is_system_prune_volumes "$cmd"; then
    echo "volume-guard: blocked. This command would remove or prune the knowledge volume ($vol). Dump first (bin/knowledge-up --dump), or target a throwaway volume. Cmd: ${cmd}" >&2
    return 2
  fi
  return 0
}

self_test() {
  local fails=0
  check() {
    local exp="$1" c="$2" got
    if decide "$c" >/dev/null 2>&1; then got=allow; else got=block; fi
    if [ "$got" = "$exp" ]; then echo "PASS $exp: $c"; else echo "FAIL want=$exp got=$got: $c"; fails=$((fails + 1)); fi
  }
  check block "docker volume rm knowledge_data"
  check block "docker volume rm -f knowledge_data"
  check block "docker rm -v knowledge"
  check block "docker rm -fv knowledge"
  check block "docker volume prune"
  check block "docker volume prune -f"
  check block "docker system prune --volumes"
  check block "docker system prune -a --volumes"
  check allow "docker ps"
  check allow "docker rm knowledge-try"
  check allow "docker system prune -f"
  [ "$fails" -eq 0 ] && { echo "volume-guard: self-test ok"; return 0; }
  return 1
}

main() {
  local input cmd
  input=$(cat)
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
  decide "$cmd"
  exit $?
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi
main
