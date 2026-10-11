#!/usr/bin/env bash
# scratch.sh: the failing hook tests for the scratch Bash wrapper, tests-first.
# Feeds hooks/scratch-wrap.sh the PreToolUse tool-call JSON on stdin, runs the rewritten command
# through bash -c, and asserts the exit code, the digest (or the unchanged output) and the stored
# row (read as the master role through the container). Each case prints PASS <name> or
# FAIL <name>: <reason>; the script exits 1 on any FAIL. With no hooks/scratch-wrap.sh yet every
# case FAILs: that is the proof the tests are not tautological.
# Run by db/tests/run.sh (it runs this with cwd=repo root and KNOWLEDGE_CONTAINER=the throwaway
# container) or standalone with KNOWLEDGE_CONTAINER set to a live knowledge container.
set -euo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$PWD}"
export CLAUDE_PLUGIN_ROOT="$ROOT"
WRAP="$ROOT/hooks/scratch-wrap.sh"
: "${KNOWLEDGE_CONTAINER:=knowledge}"
export KNOWLEDGE_CONTAINER

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

# ptu <command> <session>: the PreToolUse tool-call JSON on one line.
ptu() { jq -cn --arg c "$1" --arg s "$2" '{session_id:$s,tool_input:{command:$c}}'; }

# rewrite <command> <session>: the wrapper's rewritten command, or empty on no rewrite.
rewrite() { ptu "$1" "$2" | "$WRAP" | jq -r '.hookSpecificOutput.updatedInput.command // empty'; }

# master_q <sql>: one scalar read as the master role through the container.
master_q() { docker exec -i "$KNOWLEDGE_CONTAINER" psql -U master -d knowledge -v ON_ERROR_STOP=1 -qAt -c "$1"; }

# Should_StoreAndDigest_When_OutputOverThreshold
case_store_and_digest() {
  local name="store-and-digest" sess="t9-store-$$" cmd="seq 1 100; exit 3" w out rc lines
  if [ ! -x "$WRAP" ]; then fail "$name" "hooks/scratch-wrap.sh not found or not executable"; return; fi
  w=$(rewrite "$cmd" "$sess" || true)
  if [ -z "$w" ]; then fail "$name" "the wrapper produced no rewrite for a 100-line command"; return; fi
  if out=$(bash -c "$w"); then rc=0; else rc=$?; fi
  if [ "$rc" -ne 3 ]; then fail "$name" "exit code $rc, want 3"; return; fi
  if ! printf '%s' "$out" | grep -qE 'scratch#[0-9]+'; then fail "$name" "no scratch# id in the digest"; return; fi
  if ! printf '%s' "$out" | grep -qF '100 lines'; then fail "$name" "the digest is missing '100 lines'"; return; fi
  if ! printf '%s\n' "$out" | grep -qxF '5'; then fail "$name" "the digest head is missing line 5"; return; fi
  if ! printf '%s\n' "$out" | grep -qxF '96'; then fail "$name" "the digest tail is missing line 96"; return; fi
  if ! printf '%s\n' "$out" | grep -qxF '100'; then fail "$name" "the digest tail is missing line 100"; return; fi
  lines=$(master_q "select lines from scratch.outputs where session = '$sess'" || true)
  if [ "$lines" != "100" ]; then fail "$name" "stored lines='$lines', want 100 for session $sess"; return; fi
  pass "$name"
}

# Should_PassThrough_When_UnderThresholdOrUnreachable: under the threshold, store up.
case_passthrough_under() {
  local name="passthrough-under-threshold" sess="t9-under-$$" cmd="seq 1 40" w eff out rc
  if [ ! -x "$WRAP" ]; then fail "$name" "hooks/scratch-wrap.sh not found or not executable"; return; fi
  w=$(rewrite "$cmd" "$sess" || true)
  eff="${w:-$cmd}"
  if out=$(bash -c "$eff"); then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then fail "$name" "exit code $rc, want 0"; return; fi
  if printf '%s' "$out" | grep -q 'scratch#'; then fail "$name" "the output was replaced by a digest at or under the threshold"; return; fi
  if ! printf '%s\n' "$out" | grep -qxF '40'; then fail "$name" "the unchanged output is missing line 40"; return; fi
  if ! printf '%s\n' "$out" | grep -qxF '1'; then fail "$name" "the unchanged output is missing line 1"; return; fi
  pass "$name"
}

# Should_PassThrough_When_UnderThresholdOrUnreachable: over the threshold but store unreachable.
case_passthrough_unreachable() {
  local name="passthrough-store-unreachable" sess="t9-unreach-$$" cmd="seq 1 100; exit 2" w eff out rc
  if [ ! -x "$WRAP" ]; then fail "$name" "hooks/scratch-wrap.sh not found or not executable"; return; fi
  w=$(KNOWLEDGE_CONTAINER=knowledge-missing rewrite "$cmd" "$sess" || true)
  eff="${w:-$cmd}"
  if out=$(KNOWLEDGE_CONTAINER=knowledge-missing bash -c "$eff"); then rc=0; else rc=$?; fi
  if [ "$rc" -ne 2 ]; then fail "$name" "exit code $rc, want 2"; return; fi
  if printf '%s' "$out" | grep -q 'scratch#'; then fail "$name" "the output was replaced by a digest while the store was unreachable"; return; fi
  if ! printf '%s\n' "$out" | grep -qxF '100'; then fail "$name" "the unchanged output is missing line 100"; return; fi
  if ! printf '%s\n' "$out" | grep -qxF '1'; then fail "$name" "the unchanged output is missing line 1"; return; fi
  pass "$name"
}

# Should_PassThrough_When_UnderThresholdOrUnreachable: KNOWLEDGE_SCRATCH off -> no rewrite.
# A command that is over 20 characters and over the line threshold, so only the off flag can
# explain no rewrite (isolates the flag from the short-command skip).
case_scratch_off() {
  local name="scratch-off-no-rewrite" sess="t9-off-$$" cmd="seq 1 100 && echo off-check" w
  if [ ! -x "$WRAP" ]; then fail "$name" "hooks/scratch-wrap.sh not found or not executable"; return; fi
  w=$(KNOWLEDGE_SCRATCH=off rewrite "$cmd" "$sess" || true)
  if [ -n "$w" ]; then fail "$name" "the wrapper rewrote the command while KNOWLEDGE_SCRATCH=off"; return; fi
  pass "$name"
}

case_store_and_digest
case_passthrough_under
case_passthrough_unreachable
case_scratch_off

if [ "$fails" -gt 0 ]; then
  printf 'scratch.sh: %d case(s) failed\n' "$fails"
  exit 1
fi
exit 0
