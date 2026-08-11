#!/bin/bash
# End-to-end checks for the screen-recording CLI, against the real binary.
#
# Gated because it needs Screen Recording permission and an actual display, which
# the unit suite deliberately does not: run with DIKTA_INTEGRATION=1, or via
# `make test-integration`.
#
# Always runs against a temporary run directory and output root, so it can never
# disturb a real recording or the user's recordings folder.

set -uo pipefail

if [ "${DIKTA_INTEGRATION:-0}" != "1" ]; then
  echo "skipped (set DIKTA_INTEGRATION=1 to run; needs Screen Recording permission)"
  exit 0
fi

# The bundled binary by default: it carries the TCC grant and the settings
# domain. A bare .build binary may have neither.
DIKTA="${DIKTA:-/Applications/Dikta.app/Contents/MacOS/Dikta}"
if [ ! -x "$DIKTA" ]; then
  echo "not found: $DIKTA — run 'make install', or set DIKTA=..." >&2
  exit 1
fi

WORK="$(mktemp -d /tmp/dikta-integration.XXXXXX)"
export DIKTA_RUN_DIR="$WORK/run"
OUT="$WORK/out"
mkdir -p "$OUT"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); echo "  ✓ $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; }

# Never `status | grep`: pipefail makes the pipeline inherit status's own exit
# code, and status exits 5 when nothing is active — so a matching grep would
# still read as a failure.
status_says() { case "$("$DIKTA" status 2>/dev/null)" in *"$1"*) return 0;; *) return 1;; esac; }

expect_exit() { # description, expected code, command...
  local description="$1" expected="$2"; shift 2
  "$@" >/dev/null 2>&1
  local actual=$?
  if [ "$actual" = "$expected" ]; then pass "$description"
  else fail "$description" "expected exit $expected, got $actual"; fi
}

echo "dikta CLI integration ($DIKTA)"

# --- displays ---------------------------------------------------------------
if rows=$("$DIKTA" displays 2>/dev/null) && [ -n "$rows" ]; then
  pass "displays lists at least one screen"
else
  fail "displays lists at least one screen" "no output"
fi

if "$DIKTA" displays --json 2>/dev/null | python3 -c "
import json,sys
displays = json.load(sys.stdin)['displays']
assert displays, 'empty'
assert displays[0]['index'] == 1, 'index is not 1-based'
" 2>/dev/null; then
  pass "displays --json is 1-based and parseable"
else
  fail "displays --json is 1-based and parseable"
fi

expect_exit "displays rejects an unknown flag with 2" 2 "$DIKTA" displays --bogus

# --- nothing running --------------------------------------------------------
expect_exit "stop with nothing recording exits 5" 5 "$DIKTA" stop
expect_exit "status with nothing recording exits 5" 5 "$DIKTA" status

# --- foreground -------------------------------------------------------------
if "$DIKTA" record --foreground --for 4 --no-summarize -o "$OUT" --name fg >/dev/null 2>&1 \
   && [ -f "$OUT/fg/index.md" ]; then
  pass "foreground record writes index.md"
else
  fail "foreground record writes index.md"
fi

# --- detached lifecycle -----------------------------------------------------
session=$("$DIKTA" record --for 120 --no-summarize -o "$OUT" --name detached 2>/dev/null)
if [ "$session" = "$OUT/detached" ]; then
  pass "detached record returns the session directory once capture is live"
else
  fail "detached record returns the session directory once capture is live" "got '$session'"
fi

if status_says "cli: recording"; then
  pass "status reports the running recording"
else
  fail "status reports the running recording"
fi

expect_exit "a second record is refused with 6" 6 \
  "$DIKTA" record --for 5 -o "$OUT" --name second

if "$DIKTA" stop --timeout 300 >/dev/null 2>&1 && [ -f "$OUT/detached/index.md" ]; then
  pass "stop ends the recording and produces index.md"
else
  fail "stop ends the recording and produces index.md"
fi

expect_exit "stop is idempotent once finished" 0 "$DIKTA" stop

# --- death and recovery -----------------------------------------------------
# The reason liveness is a lock rather than a PID: SIGKILL leaves no chance to
# clean up, and the next record must still be able to claim the slot.
"$DIKTA" record --for 120 --no-summarize -o "$OUT" --name killed >/dev/null 2>&1
pid=$(python3 -c "
import json
print(json.load(open('$DIKTA_RUN_DIR/cli.json'))['pid'])
" 2>/dev/null)
if [ -n "${pid:-}" ] && kill -9 "$pid" 2>/dev/null; then
  sleep 1
  if status_says "stale"; then
    pass "status reports a killed recorder as stale"
  else
    fail "status reports a killed recorder as stale"
  fi
  if session=$("$DIKTA" record --for 3 --no-summarize -o "$OUT" --name after-kill 2>/dev/null) \
     && [ -n "$session" ]; then
    pass "a new recording can claim the lock after a SIGKILL"
    "$DIKTA" stop --timeout 300 >/dev/null 2>&1
  else
    fail "a new recording can claim the lock after a SIGKILL"
  fi
else
  fail "status reports a killed recorder as stale" "could not read the pid"
fi

# --- surviving the parent shell --------------------------------------------
# The whole reason record detaches itself rather than trusting the caller.
bash -c "'$DIKTA' record --for 120 --no-summarize -o '$OUT' --name orphan >/dev/null 2>&1"
sleep 1
if status_says "cli: recording"; then
  pass "the recorder survives the shell that started it"
  "$DIKTA" stop --timeout 300 >/dev/null 2>&1
else
  fail "the recorder survives the shell that started it"
fi

echo ""
if [ "$FAILED" = 0 ]; then
  echo "$PASSED passed"
  exit 0
fi
echo "$PASSED passed, $FAILED FAILED"
exit 1
