#!/usr/bin/env bash
# Opt-in real Codex native hc secondmate lifecycle in a genuinely seeded home.
# Uses the hc lab helper and its tripwire. On an active production core, run
# within an externally verified kernel isolation boundary; never waive drift.
# Only test-owned stock project hooks are trusted through the native UI, using
# a disposable CODEX_HOME. Production hook consent is never modified.
set -Eeuo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_HC_SECONDMATE_LIVE codex herdr-core jq
trap 'echo "FAIL: native hc/Codex guard at line $LINENO: $BASH_COMMAND" >&2' ERR
# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"
TMP_ROOT=$(fm_test_tmproot fm-hc-secondmate-live)
PROOF_BASE=${FM_HC_SECONDMATE_PROOF_DIR:-$TMP_ROOT/proof}
mkdir -p "$PROOF_BASE" "$TMP_ROOT/codex"
PROOF=$(mktemp -d "$PROOF_BASE/run.XXXXXX")
printf 'proof=%s\n' "$PROOF"
source_codex_home=${CODEX_HOME:-$HOME/.codex}
[ ! -f "$source_codex_home/auth.json" ] || cp "$source_codex_home/auth.json" "$TMP_ROOT/codex/auth.json"
export CODEX_HOME=$TMP_ROOT/codex
printf 'model = "gpt-6.1-sol"\n' > "$CODEX_HOME/config.toml"
export FM_HOME=$TMP_ROOT/parent
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME" >/dev/null
export FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=0
export FM_HC_SECONDMATE_READY_POLLS=240
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'codex gpt-6.1-sol low\n' > "$FM_HOME/config/secondmate-harness"
printf 'herdr\n' > "$FM_HOME/config/backend"
printf 'CODEX_HOME\nXDG_STATE_HOME\nXDG_CONFIG_HOME\nXDG_DATA_HOME\nFM_HC_SOCKET\nFM_HC_BIN\n' > "$FM_HOME/config/launch-env-allowlist"
HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name native-secondmate)
spawn_pid='' target=''
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$spawn_pid" ]; then kill "$spawn_pid" 2>/dev/null || true; wait "$spawn_pid" 2>/dev/null || true; fi
  if [ -n "$target" ]; then
    "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" read --lines 200 "${target#*:}" > "$PROOF/capture.txt" 2>&1 || true
  fi
  [ ! -f "$FM_HOME/state/mate.meta" ] || cp "$FM_HOME/state/mate.meta" "$PROOF/meta.txt"
  [ ! -f "$TMP_ROOT/mate/state/.hc-secondmate.json" ] || cp "$TMP_ROOT/mate/state/.hc-secondmate.json" "$PROOF/binding.json"
  [ ! -f "$TMP_ROOT/mate/state/.lock" ] || cp "$TMP_ROOT/mate/state/.lock" "$PROOF/lock.txt"
  [ ! -f "$TMP_ROOT/mate/state/.supervise-daemon.log" ] || cp "$TMP_ROOT/mate/state/.supervise-daemon.log" "$PROOF/supervision-daemon.log"
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES"
export HC_SESSION=$HC_TEST_SES FM_HC_SOCKET
FM_HC_SOCKET=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
lab="$(hc_test_lab_dir)/$HC_TEST_SES"
export XDG_STATE_HOME="$lab/env/xdg-state" XDG_CONFIG_HOME="$lab/env/xdg-config" XDG_DATA_HOME="$lab/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET
export FM_SECONDMATE_CHARTER='This is an isolated native hc lifecycle verification. Your only work is to run bin/fm-session-start.sh, verify your own home lock, run python3 native-tool-proof.py, then write native-ready to data/native-ready, and handle parent inbox requests through bin/fm-secondmate-report.sh using their correlation token. Do not launch workers or investigate other homes. Test-owned child records and project files must be preserved exactly; their endpoints belong to the test controller. Once ready, wait for the parent.'
export FM_SECONDMATE_SCOPE='isolated native hc lifecycle verification'
"$ROOT/bin/fm-home-seed.sh" mate "$TMP_ROOT/mate" --no-projects >/dev/null
# A working-tree test must exercise its current source, including uncommitted
# fixes, inside the genuine seeded clone, rather than the clone's old HEAD.
cp -a "$ROOT/bin/." "$TMP_ROOT/mate/bin/"
cat > "$TMP_ROOT/mate/native-tool-proof.py" <<'PY'
import json, os, pathlib
pid=os.getpid(); ancestry=[]
while pid>1:
    ancestry.append(pid)
    pid=int(pathlib.Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[1])
receipt=dict(ancestry=ancestry,env={key:os.environ.get(key) for key in ('FM_HOME','HC_SESSION','HC_SCOPE','HC_TERMINAL_ID','HC_TERMINAL_SOCKET')})
pathlib.Path('data/native-tool-context.json').write_text(json.dumps(receipt))
PY
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc

# Trust only this test's seeded project via native interaction. The auth copy
# has no user hooks or settings; the hooks being accepted are our stock fixture.
trust_fixture() {
  local screen
  screen=$(fm_backend_hc_visible_capture "$target" fm-mate) || return 0
  if printf '%s' "$screen" | grep -qF 'Trust this folder?'; then
    fm_backend_hc_send_key "$target" Enter fm-mate
  elif printf '%s' "$screen" | grep -qF '2. Trust all and continue'; then
    fm_backend_hc_send_key "$target" Down fm-mate
    fm_backend_hc_send_key "$target" Enter fm-mate
  fi
}
wait_ready() {
  local i
  for i in $(seq 1 600); do
    [ -e "$FM_HOME/state/mate.meta" ] && target=$(fm_backend_target_of_meta "$FM_HOME/state/mate.meta")
    [ -z "$target" ] || trust_fixture
    [ ! -f "$TMP_ROOT/mate/data/native-ready" ] || break
    sleep 0.2
  done
  [ -f "$TMP_ROOT/mate/data/native-ready" ] || fail 'real Codex did not finish home-scoped startup'
  wait "$spawn_pid" || fail 'native spawn readiness failed'
  spawn_pid=
  [ "$(fm_backend_agent_state hc "$target" fm-mate)" = alive ] || fail 'ready marker without live agent'
  [ -f "$TMP_ROOT/mate/state/.session-start-complete" ] || fail 'session-start did not complete in own home'
}
"$ROOT/bin/fm-spawn.sh" mate "$TMP_ROOT/mate" --secondmate --backend hc --harness codex --model gpt-6.1-sol --effort low > "$PROOF/spawn.txt" 2>&1 &
spawn_pid=$!
wait_ready
. "$ROOT/bin/fm-hc-secondmate-lib.sh"
owner=$(cat "$TMP_ROOT/mate/state/.lock")
fm_hc_secondmate_lock_owner "$TMP_ROOT/mate" "$owner" "$target" || fail 'startup locked a foreign harness'
python3 - "$owner" "$TMP_ROOT/mate" "$target" <<'PY'
import json, pathlib, sys
pid,home,target=sys.argv[1:]
values=dict(entry.split(b'=',1) for entry in open('/proc/'+pid+'/environ','rb').read().split(b'\0') if b'=' in entry)
assert values[b'FM_HOME'].decode()==home
assert values[b'FM_SUPERVISOR_BACKEND']==b'hc'
assert values[b'FM_SUPERVISOR_TARGET'].decode()==target
assert b'FM_BACKEND' not in values, 'native endpoint must not override future worker backend'
receipt=json.loads(pathlib.Path(home,'data/native-tool-context.json').read_text())
assert int(pid) in receipt['ancestry'], 'actual tool execution escaped the home-owning Codex'
assert receipt['env']['FM_HOME']==home
assert receipt['env']['HC_SESSION']==target.split(':')[0]
assert receipt['env']['HC_TERMINAL_ID']==target.split(':')[1]
assert receipt['env']['HC_TERMINAL_SOCKET'], 'tool lost its native hc socket context'
PY
cp "$TMP_ROOT/mate/data/native-tool-context.json" "$PROOF/tool-context.json"
assert_equals "$(cat "$TMP_ROOT/mate/config/backend")" herdr 'mate retains inherited worker backend'
[ ! -e "$FM_HOME/state/.lock" ] || fail 'child acquired parent lock'
json=$(fm_backend_hc_get "$target")
printf '%s\n' "$json" > "$PROOF/terminal.json"
printf '%s' "$json" | jq -e '.parent == null and .die_with_parent == false and .notify == false
  and (.labels["herdr.space"] | length > 0) and (.labels["herdr.tab"] | length > 0)' >/dev/null || fail 'native endpoint lifetime or app labels missing'
app_tab=$(printf '%s' "$json" | jq -r '.labels["herdr.tab"]')
pass 'real Codex startup has native hc endpoint, own lock, app labels, and independent lifetime flags'

# A second launch must refuse without changing its incarnation or home lock.
cp "$FM_HOME/state/mate.meta" "$PROOF/meta-before.txt"
if "$ROOT/bin/fm-spawn.sh" mate --secondmate --backend hc > "$PROOF/duplicate.txt" 2>&1; then fail 'duplicate spawn accepted'; fi
cmp "$FM_HOME/state/mate.meta" "$PROOF/meta-before.txt" || fail 'duplicate spawn rewrote metadata'
assert_equals "$(cat "$TMP_ROOT/mate/state/.lock")" "$owner" 'duplicate retains owner'

"$ROOT/bin/fm-send.sh" mate 'Reply through bin/fm-secondmate-report.sh with this request correlation token and exact note native-inbox-ack. Acknowledge this inbox record by moving it into handled/.' > "$PROOF/send.txt" 2>&1
for _ in $(seq 1 600); do
  if grep -q 'native-inbox-ack' "$FM_HOME/state/mate.status" 2>/dev/null && [ -f "$FM_HOME/state/mate.inbox/handled/001.msg" ]; then break; fi
  sleep 0.2
done
[ -f "$FM_HOME/state/mate.inbox/handled/001.msg" ] || fail 'real agent did not acknowledge durable inbox'
. "$ROOT/bin/fm-task-inbox-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
corr=$(fm_pending_reply_extract_corr "$(fm_task_inbox_body "$FM_HOME/state/mate.inbox/handled/001.msg")")
[ -n "$corr" ] || fail 'request correlation missing'
fm_pending_reply_try_resolve "$FM_HOME/state" "$corr" || fail 'real parent report did not resolve correlation'
assert_equals "$(fm_pending_reply_get "$FM_HOME/state/pending-replies/$corr" phase)" resolved 'correlated reply resolved'
cp "$FM_HOME/state/mate.status" "$PROOF/status.txt"
pass 'real native secondmate handled durable inbox and resolved the parent request through its status channel'

for _ in $(seq 1 200); do
  if [ "$(fm_backend_hc_busy_state "$target" fm-mate)" = idle ] \
    && [ "$(fm_backend_hc_composer_state "$target" fm-mate)" = empty ]; then break; fi
  sleep 0.2
done
fm_backend_hc_send_key "$target" x fm-mate
if "$ROOT/bin/fm-control.sh" mate exit > "$PROOF/pending-refusal.txt" 2>&1; then fail 'exit accepted real pending input'; fi
assert_grep 'pending text' "$PROOF/pending-refusal.txt" 'pending refusal names actual input'
assert_equals "$(fm_backend_agent_state hc "$target" fm-mate)" alive 'pending refusal preserves agent'
fm_backend_hc_send_key "$target" C-u fm-mate
cp "$FM_HOME/state/mate.meta" "$PROOF/owned-core.meta"
sed 's/^hc_core_id=.*/hc_core_id=foreign-core/' "$PROOF/owned-core.meta" > "$FM_HOME/state/mate.meta"
if "$ROOT/bin/fm-control.sh" mate exit > "$PROOF/core-refusal.txt" 2>&1; then fail 'foreign core accepted lifecycle'; fi
cp "$PROOF/owned-core.meta" "$FM_HOME/state/mate.meta"
assert_equals "$(fm_backend_agent_state hc "$target" fm-mate)" alive 'foreign core refusal preserves agent'
pass 'real pending input and mismatched core identity refuse lifecycle without stopping Codex'

# Exercise the away daemon's actual guarded injection primitive from the
# child's home. The native binding authorizes only this parent's labelled
# endpoint; the test starts no daemon or watcher and touches no child tree.
FM_HOME="$TMP_ROOT/mate" FM_ROOT_OVERRIDE="$TMP_ROOT/mate" \
  FM_SUPERVISOR_BACKEND=hc FM_SUPERVISOR_TARGET="$target" FM_DAEMON_PRIMARY_HARNESS=codex \
  bash -c '
    . "$1/bin/fm-supervise-daemon.sh"
    afk_enter "$FM_HOME/state"
    if ! inject_msg "Isolated supervision delivery probe: write native-supervision-ack to data/native-supervision-ack. Do not start a watcher or take new work." "$FM_HOME/state"; then
      printf "supervision refused: %s\n" "$INJECT_LAST_FAILURE" >&2
      exit 1
    fi
  ' bash "$ROOT" > "$PROOF/supervision.txt" 2>&1 || { cat "$PROOF/supervision.txt"; fail 'native supervisor injection'; }
for _ in $(seq 1 600); do
  [ ! -f "$TMP_ROOT/mate/data/native-supervision-ack" ] || break
  sleep 0.2
done
[ -f "$TMP_ROOT/mate/data/native-supervision-ack" ] || fail 'real agent did not receive home-scoped supervision'
rm "$TMP_ROOT/mate/state/.afk"
pass 'native home supervisor injection reaches its own real Codex through the guarded daemon primitive'

# Preserve a child's endpoint plus durable and uncommitted work through exit,
# relaunch, and recovery. No child lifecycle is delegated to the parent.
child=$(fm_backend_hc_create_task "$HC_SESSION" fm-child "$TMP_ROOT")
printf 'backend=hc\nwindow=%s:%s\nendpoint_task_id=child\nkind=ship\n' "$HC_SESSION" "$child" > "$TMP_ROOT/mate/state/child.meta"
printf 'unlanded work\n' > "$TMP_ROOT/mate/retained-work.txt"
printf '## Queued\n- [ ] retained - saved work\n' > "$TMP_ROOT/mate/data/backlog.md"
cp "$TMP_ROOT/mate/state/child.meta" "$PROOF/child-before.txt"
cp "$TMP_ROOT/mate/data/backlog.md" "$PROOF/backlog-before.txt"
old_target=$target
"$ROOT/bin/fm-control.sh" mate exit > "$PROOF/exit.txt" 2>&1 || { cat "$PROOF/exit.txt"; fail 'real Codex graceful exit'; }
assert_equals "$(fm_backend_agent_state hc "$target" fm-mate)" dead 'graceful exit proved no agent'
rm "$TMP_ROOT/mate/data/native-ready"
"$ROOT/bin/fm-control.sh" mate relaunch > "$PROOF/relaunch.txt" 2>&1 &
spawn_pid=$!
wait_ready
assert_equals "$target" "$old_target" 'relaunch keeps native endpoint'
[ "$(cat "$TMP_ROOT/mate/state/.lock")" != "$owner" ] || fail 'relaunch retained obsolete lock owner'
assert_equals "$(cat "$TMP_ROOT/mate/retained-work.txt")" 'unlanded work' 'uncommitted work retained'
cmp "$TMP_ROOT/mate/state/child.meta" "$PROOF/child-before.txt" || fail 'child metadata changed'
cmp "$TMP_ROOT/mate/data/backlog.md" "$PROOF/backlog-before.txt" || fail 'backlog changed'
fm_backend_target_exists hc "$HC_SESSION:$child" fm-child || fail 'child endpoint did not outlive parent agent'
pass 'graceful exit and relaunch retain same home, endpoint, backlog, uncommitted work, and independent child'

"$ROOT/bin/fm-control.sh" mate exit > "$PROOF/exit-recovery.txt" 2>&1
fm_backend_hc_kill "$target" '' fm-mate
rm "$TMP_ROOT/mate/data/native-ready"
. "$ROOT/bin/fm-secondmate-liveness-lib.sh"
STATE="$FM_HOME/state"
fm_secondmate_liveness_probe "$STATE/mate.meta" mate poll
assert_equals "$FM_SM_LIVE_STATUS" relaunchable 'missing owned endpoint is recoverable'
# Deliberately wrong ambient session must not relocate the replacement.
HC_SESSION=wrong-ambient fm_secondmate_liveness_relaunch "$STATE/mate.meta" mate > "$PROOF/recovery.txt" 2>&1 &
spawn_pid=$!
wait_ready
[ "$target" != "$old_target" ] || fail 'missing endpoint was not replaced'
assert_equals "${target%%:*}" "$HC_TEST_SES" 'recovery uses recorded core'
assert_equals "$(fm_backend_hc_get "$target" | jq -r '.labels["herdr.tab"]')" "$app_tab" 'recovery adopts same app tab label'
fm_secondmate_liveness_probe "$STATE/mate.meta" mate poll
assert_equals "$FM_SM_LIVE_STATUS" alive 'recovered endpoint does not prompt duplicate recovery'
cmp "$TMP_ROOT/mate/state/child.meta" "$PROOF/child-before.txt" || fail 'recovery changed child metadata'
fm_backend_target_exists hc "$HC_SESSION:$child" fm-child || fail 'recovery killed independent child'
pass 'recovery preserves recorded core and home, adopts app tab label, and converges without duplicates'
printf 'hc=%s codex=%s\n' "$(herdr-core --version)" "$(codex --version)"
echo FM_TEST_COMPLETE
