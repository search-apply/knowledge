#!/usr/bin/env bash
# skills.sh: the hook tests for the two skills (Should_CarryTheRules_When_SkillsRead).
# For each skill: wc -l at most 100, and a grep for every phrase the contract names finds it in
# the named file. Each case prints PASS <name> or FAIL <name>: <reason>; the script exits 1 on
# any FAIL. Run by db/tests/run.sh (cwd=repo root) or standalone from the repo root.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$PWD}"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

# check_lines <file> <max>: the file exists and holds at most <max> lines.
check_lines() {
  local file="$ROOT/$1" max="$2" n
  if [ ! -f "$file" ]; then fail "lines $1" "file not found"; return; fi
  n=$(wc -l < "$file")
  if [ "$n" -gt "$max" ]; then fail "lines $1" "$n lines, want at most $max"; return; fi
  pass "lines $1 ($n)"
}

# check_phrase <file> <phrase>: the phrase appears verbatim in the file.
check_phrase() {
  local file="$ROOT/$1" phrase="$2"
  if grep -qF -- "$phrase" "$file"; then pass "phrase $1 <$phrase>"; else fail "phrase $1 <$phrase>" "not found"; fi
}

check_lines skills/knowledge/SKILL.md 100
check_lines skills/data/SKILL.md 100

for p in "one sentence" "knowledge.current" "knowledge.notes" "knowledge.tasks" "knowledge.sessions" "main session"; do
  check_phrase skills/knowledge/SKILL.md "$p"
done

for p in "knowledge.datasets" "created_at" "knowledge.<project>_<topic>" "Always a limit" "five-second statement timeout"; do
  check_phrase skills/data/SKILL.md "$p"
done

if [ "$fails" -gt 0 ]; then
  printf 'skills.sh: %d case(s) failed\n' "$fails"
  exit 1
fi
exit 0
