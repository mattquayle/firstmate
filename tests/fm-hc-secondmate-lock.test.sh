#!/usr/bin/env bash
# shellcheck disable=SC2016 # Scripts passed to child shells expand their own variables.
# Native hc home locks: real process ancestry, foreign live owner refusal,
# stale incarnation/malformed binding refusal, and child work preservation.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-hc-secondmate-lock)
mkdir -p "$TMP_ROOT/mate/state" "$TMP_ROOT/bin" "$TMP_ROOT/parent/state"
printf 'mate\n' > "$TMP_ROOT/mate/.fm-secondmate-home"
printf 'unlanded child work\n' > "$TMP_ROOT/mate/state/child.meta"
ln -s /bin/bash "$TMP_ROOT/bin/codex"
export TEST_ROOT=$ROOT TEST_TMP=$TMP_ROOT

# Reproduce the legacy ownership hole without touching a real home: a harness
# outside an unbound destination can claim it just by setting FM_HOME. Native
# bindings below must reject the same cross-home action.
mkdir -p "$TMP_ROOT/unbound/state"
printf 'unbound\n' > "$TMP_ROOT/unbound/.fm-secondmate-home"
FM_HOME="$TMP_ROOT/unbound" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' \
  "$TMP_ROOT/bin/codex" -c 'bash "$TEST_ROOT/bin/fm-lock.sh"; printf "%s\n" "$$" > "$TEST_TMP/legacy-owner"' >/dev/null
assert_equals "$(cat "$TMP_ROOT/unbound/state/.lock")" "$(cat "$TMP_ROOT/legacy-owner")" 'legacy lock accepts caller harness in another home'
pass 'safe reproduction: an unbound home can inherit the caller harness as its lock owner'

# The terminal shell launches a harness-shaped child, which executes the real
# lock executable. No mocked ps/kill result can make the ancestry verdict pass.
cat > "$TMP_ROOT/terminal.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "$TEST_ROOT/bin/fm-hc-secondmate-lib.sh"
stamp=$(fm_hc_secondmate_pid_stamp $$)
jq -n --arg home "$TEST_TMP/mate" --arg pid "$$" --arg stamp "$stamp" \
  '{version:1,home:$home,id:"mate",target:"lab:t1",pid:$pid,stamp:$stamp}' > "$TEST_TMP/mate/state/.hc-secondmate.json"
"$TEST_TMP/bin/codex" -c '
  FM_HOME="$TEST_TMP/mate" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' bash "$TEST_ROOT/bin/fm-lock.sh"
  printf "%s\n" "$$" > "$TEST_TMP/owner"
  while [ ! -f "$TEST_TMP/release" ]; do sleep 0.1; done
' > "$TEST_TMP/lock.out" 2>&1
SH
bash "$TMP_ROOT/terminal.sh" &
terminal=$!
cleanup() {
  touch "$TMP_ROOT/release"
  wait "$terminal" || true
  fm_test_cleanup
}
trap cleanup EXIT
for _ in $(seq 1 100); do [ ! -f "$TMP_ROOT/owner" ] || break; sleep 0.1; done
[ -f "$TMP_ROOT/owner" ] || { cat "$TMP_ROOT/lock.out"; fail 'native home lock not acquired'; }
owner=$(cat "$TMP_ROOT/owner")
assert_equals "$(cat "$TMP_ROOT/mate/state/.lock")" "$owner" 'lock belongs to child harness'
# A second independent harness cannot take this lock even by supplying FM_HOME.
if FM_HOME="$TMP_ROOT/mate" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' \
  "$TMP_ROOT/bin/codex" -c 'bash "$TEST_ROOT/bin/fm-lock.sh"; rc=$?; exit "$rc"' > "$TMP_ROOT/refused" 2>&1; then
  fail 'foreign harness acquired child home'
fi
assert_grep 'does not belong' "$TMP_ROOT/refused" 'foreign home diagnostic'
assert_equals "$(cat "$TMP_ROOT/mate/state/.lock")" "$owner" 'foreign refusal retains owner'
. "$ROOT/bin/fm-hc-secondmate-lib.sh"
if fm_hc_secondmate_require_unlocked "$TMP_ROOT/mate" >/dev/null 2>&1; then fail 'live home admitted for spawn'; fi
fm_hc_secondmate_control_safe "$TMP_ROOT/mate" lab:t1 || fail 'matching endpoint could not control its own lock'
if fm_hc_secondmate_control_safe "$TMP_ROOT/mate" lab:t2 >/dev/null 2>&1; then fail 'foreign endpoint accepted live lock'; fi
pass 'native hc home lock binds actual terminal ancestry and refuses foreign control or duplicate spawn'

# A primary can still acquire its own separate home; the child pid never leaks.
FM_HOME="$TMP_ROOT/parent" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' \
  "$TMP_ROOT/bin/codex" -c 'bash "$TEST_ROOT/bin/fm-lock.sh"; rc=$?; exit "$rc"' > "$TMP_ROOT/parent.out"
[ "$(cat "$TMP_ROOT/parent/state/.lock")" != "$owner" ] || fail 'cross-home lock alias'
touch "$TMP_ROOT/release"
wait "$terminal"
fm_hc_secondmate_require_unlocked "$TMP_ROOT/mate" || fail 'stale owner blocked replacement'
if fm_hc_secondmate_lock_owner "$TMP_ROOT/mate" "$owner" lab:t1; then fail 'dead terminal incarnation accepted'; fi
printf '{}\n' > "$TMP_ROOT/mate/state/.hc-secondmate.json"
if FM_HOME="$TMP_ROOT/mate" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' \
  "$TMP_ROOT/bin/codex" -c 'bash "$TEST_ROOT/bin/fm-lock.sh"; rc=$?; exit "$rc"' >/dev/null 2>&1; then fail 'malformed binding accepted'; fi
assert_equals "$(cat "$TMP_ROOT/mate/state/child.meta")" 'unlanded child work' 'all refusals preserve child records'
printf 'not-a-pid\n' > "$TMP_ROOT/mate/state/.lock"
if fm_hc_secondmate_require_unlocked "$TMP_ROOT/mate" >/dev/null 2>&1; then fail 'malformed lock accepted for launch'; fi
printf '%s\n' "$$" > "$TMP_ROOT/mate/state/.lock"
if fm_hc_secondmate_require_unlocked "$TMP_ROOT/mate" >/dev/null 2>&1; then fail 'live non-harness owner treated as stale'; fi
rm "$TMP_ROOT/mate/state/.lock"
ln -s "$TMP_ROOT/parent/state/.lock" "$TMP_ROOT/mate/state/.lock"
if fm_hc_secondmate_require_unlocked "$TMP_ROOT/mate" >/dev/null 2>&1; then fail 'symlinked lock accepted'; fi
pass 'separate homes keep independent locks; stale and malformed endpoint incarnations fail closed'
echo FM_TEST_COMPLETE
