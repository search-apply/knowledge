#!/usr/bin/env bash
# index-headings.sh: the headings-indexer hook test for bin/index-headings. Writes two fixture markdown
# files with four headings in a temp dir, runs the indexer, and reads the stored section rows
# back as the master role through the container. Each case prints PASS <name> or
# FAIL <name>: <reason>; the script exits 1 on any FAIL.
# Run by db/tests/run.sh (cwd=repo root, KNOWLEDGE_CONTAINER=the throwaway container) or
# standalone with KNOWLEDGE_CONTAINER set to a live knowledge container.
set -euo pipefail

ROOT="$PWD"
BIN="$ROOT/bin/index-headings"
: "${KNOWLEDGE_CONTAINER:=knowledge}"
export KNOWLEDGE_CONTAINER

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

master_q() { docker exec -i "$KNOWLEDGE_CONTAINER" psql -U master -d knowledge -v ON_ERROR_STOP=1 -qAt -c "$1"; }

# run_indexer <args...>: runs the indexer with cwd=the fixture dir, so a key's file is just
# the fixture's own relative name ("one.md#..."), not a long "../.." chain from the repo root.
run_indexer() { (cd "$TMP" && "$BIN" "$@"); }

PROJECT="t-idx-$$"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

write_fixtures() {
  cat > "$TMP/one.md" <<'EOF'
# First Heading

Some first content.

## Second Heading
Some second content.
EOF
  cat > "$TMP/two.md" <<'EOF'
# Third Heading

Some third content.

# Fourth Heading
Some fourth content.
EOF
}

current_text() { master_q "select text from knowledge.current where project = '$PROJECT' and kind = 'section' and key = '$1'"; }
current_id() { master_q "select id from knowledge.current where project = '$PROJECT' and kind = 'section' and key = '$1'"; }

case_first_run() {
  local name="first-run-four-current-rows"
  if [ ! -x "$BIN" ]; then fail "$name" "bin/index-headings not found or not executable"; return; fi
  write_fixtures
  local out
  out="$(run_indexer "$PROJECT" ".")" || { fail "$name" "index-headings exited non-zero: $out"; return; }
  if ! printf '%s' "$out" | grep -qE '^indexed 2 files, 4 headings, 0 retired$'; then
    fail "$name" "unexpected summary line: $out"; return
  fi
  local n
  n="$(master_q "select count(*) from knowledge.current where project = '$PROJECT' and kind = 'section'")"
  if [ "$n" != "4" ]; then fail "$name" "current section rows = $n, want 4"; return; fi

  local key="one.md#first-heading" fields lines summary
  if [ "$(current_text "$key")" != $'First Heading\nSome first content.' ]; then
    fail "$name" "unexpected text for $key"; return
  fi
  fields="$(master_q "select fields from knowledge.current where project = '$PROJECT' and kind = 'section' and key = '$key'")"
  lines="$(printf '%s' "$fields" | jq -r '.lines')"
  summary="$(printf '%s' "$fields" | jq -r '.summary')"
  if [ "$lines" != "1-6" ]; then fail "$name" "lines for $key = $lines, want 1-6"; return; fi
  if [ "$summary" != "Some first content." ]; then fail "$name" "summary for $key = $summary"; return; fi
  pass "$name"
}

case_dry_run_writes_nothing() {
  local name="dry-run-writes-nothing"
  if [ ! -x "$BIN" ]; then fail "$name" "bin/index-headings not found or not executable"; return; fi
  local proj="t-idx-dry-$$" out n
  out="$(run_indexer --dry-run "$proj" ".")" || { fail "$name" "dry-run exited non-zero: $out"; return; }
  if ! printf '%s' "$out" | grep -qi 'knowledge.put'; then fail "$name" "dry-run printed no SQL"; return; fi
  n="$(master_q "select count(*) from knowledge.current where project = '$proj' and kind = 'section'")"
  if [ "$n" != "0" ]; then fail "$name" "dry-run wrote $n rows, want 0"; return; fi
  pass "$name"
}

case_rerun_after_edit() {
  local name="rerun-supersedes-edited-heading-keeps-untouched-ids"
  if [ ! -x "$BIN" ]; then fail "$name" "bin/index-headings not found or not executable"; return; fi
  local untouched="two.md#third-heading" old_key="one.md#second-heading" new_key="one.md#second-heading-edited"
  local id_before id_after out
  id_before="$(current_id "$untouched")"

  cat > "$TMP/one.md" <<'EOF'
# First Heading

Some first content.

## Second Heading Edited
Some second content.
EOF
  out="$(run_indexer "$PROJECT" ".")" || { fail "$name" "index-headings exited non-zero: $out"; return; }
  if ! printf '%s' "$out" | grep -qE '^indexed 2 files, 4 headings, 1 retired$'; then
    fail "$name" "unexpected summary line: $out"; return
  fi

  if [ "$(current_text "$old_key")" != "removed" ]; then
    fail "$name" "old key $old_key not superseded with 'removed'"; return
  fi
  if [ "$(current_text "$new_key")" != $'Second Heading Edited\nSome second content.' ]; then
    fail "$name" "new key $new_key not current with the edited text"; return
  fi
  id_after="$(current_id "$untouched")"
  if [ "$id_after" != "$id_before" ]; then
    fail "$name" "untouched key $untouched changed id ($id_before -> $id_after)"; return
  fi
  pass "$name"
}

case_first_run
case_dry_run_writes_nothing
case_rerun_after_edit

if [ "$fails" -gt 0 ]; then
  printf 'index-headings.sh: %d case(s) failed\n' "$fails"
  exit 1
fi
exit 0
