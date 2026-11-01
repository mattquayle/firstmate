#!/usr/bin/env bash
# tests/fm-backend-hc-smoke.test.sh - real herdr-core smoke test for the hc
# session-provider adapter (bin/backends/hc.sh, docs/hc-backend.md).
# Every other hc suite fakes the CLI; this one drives the REAL hc binary, but
# only inside a lab session provisioned by bin/fm-hc-lab.sh: a unique
# fm-hclab-* HC_SESSION, scratch XDG roots, a pinned FM_HC_SOCKET, a
# real-fleet tripwire, and a teardown that sweeps the session's serve/hold
# daemons by their HC_SESSION env marker. tests/hc-test-safety.sh owns the
# only sanctioned teardown path and teardown failures propagate through the
# EXIT trap.
#
# Covers one task lifecycle through the bin/fm-backend.sh dispatcher: binary
# and generation gates, container ensure, create, submitted input, cwd
# tracking, capture, agent state for a shell and for an agent-named process,
# and a proven close.
#
# Skips cleanly (exit 0, "skip: hc not found ...") when no herdr-core binary
# is installed (optional-binary gate); to pin a specific binary run
# `FM_HC_BIN=/path/to/hc bash tests/fm-backend-hc-smoke.test.sh`. Once the
# binary is present, a provisioning or teardown failure is a FAIL, not a
# skip.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# Binary resolution identical to the adapter, installer, and lab: FM_HC_BIN
# wins, then herdr-core, then the hc alias.
HC_BIN=${FM_HC_BIN:-}
[ -n "$HC_BIN" ] || HC_BIN=$(command -v herdr-core 2>/dev/null || true)
[ -n "$HC_BIN" ] || HC_BIN=$(command -v hc 2>/dev/null || true)
if [ -z "$HC_BIN" ] || [ ! -x "$HC_BIN" ]; then
  echo "skip: hc not found (install via bin/fm-install-hc.sh or set FM_HC_BIN)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the hc adapter)"; exit 0; }
export FM_HC_BIN=$HC_BIN

# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-smoke)

HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name smoke)

# The teardown's own result propagates: a fleet-tripwire failure or surviving
# session processes keep this run nonzero even on an otherwise-clean pass.
# Armed before provision so a half-provisioned session is still swept when
# the lab helper left a tripwire behind.
cleanup_lab() {
  local rc=$?
  trap - EXIT
  hc_test_safe_teardown "$ROOT" "$HC_TEST_SES" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_lab EXIT

"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES" \
  || fail "hc lab could not provision with $HC_BIN"
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
[ -n "$HC_TEST_SOCK" ] || fail "hc lab provisioned without a socket"

hc_test_refuse_if_unsafe "$HC_TEST_SES" \
  || fail "provisioned session '$HC_TEST_SES' does not satisfy the lab safety contract"

HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
export HC_SESSION=$HC_TEST_SES FM_HC_SOCKET=$HC_TEST_SOCK
export XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state" \
  XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" \
  XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET

FM_HOME_DIR=$TMP_ROOT/home
WORK_DIR=$TMP_ROOT/work
mkdir -p "$FM_HOME_DIR" "$WORK_DIR"
WORK_DIR=$(cd "$WORK_DIR" && pwd -P)
export FM_HOME=$FM_HOME_DIR FM_ROOT_OVERRIDE=$FM_HOME_DIR

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || fail "could not source the hc adapter"

# wait_for <seconds> <cmd...>: poll a condition without a fixed sleep budget.
wait_for() {
  local tries=$(( $1 * 10 ))
  shift
  while [ "$tries" -gt 0 ]; do
    "$@" && return 0
    tries=$((tries - 1))
    sleep 0.1
  done
  return 1
}

# Parent hierarchy is a protocol fact. The native-lock consumer below is a
# Bash fixture named codex, not a vendor harness or a model-string assertion.
# Real vendor tool context remains owned by the credentialed secondmate guard.
unset FM_HC_PARENT_TARGET FM_HC_PARENT_CORE_ID FM_SUPERVISOR_BACKEND FM_SUPERVISOR_TARGET
PARENT_CORE=$(fm_backend_hc_core_id "$HC_SESSION") || fail 'parent core handshake'
PARENT=$(fm_backend_hc_cli "$HC_SESSION" run --bg --json --no-parent --outlive-parent --no-notify \
  --cwd "$WORK_DIR" -- bash --noprofile --norc | jq -er .address) || fail 'shell parent'
MATE=$(FM_HC_PARENT_TARGET="$HC_SESSION:$PARENT" FM_HC_PARENT_CORE_ID="$PARENT_CORE" \
  fm_backend_hc_create_task "$HC_SESSION" fm-mate "$WORK_DIR" secondmate) || fail 'linked mate shell'
parent_is() { # <address> <expected-parent>
  fm_backend_hc_get "$HC_SESSION:$1" | jq -e --arg p "$2" \
    '.parent == $p and .state == "live" and .die_with_parent == false and .notify == false' >/dev/null
}
parent_is "$MATE" "$PARENT" || fail 'core did not return the parent and independent lifetime flags'
pass 'hc hierarchy: explicit primary -> mate link returned by real core'
MATE_NAME=$(fm_backend_hc_get "$HC_SESSION:$MATE" | jq -er '.name | select(test("^mate-supervisor-[0-9a-f]{8}$"))') || fail 'real secondmate role name'

# Bind the scratch mate home to that terminal's actual shell incarnation.
MATE_HOME="$TMP_ROOT/mate"
mkdir -p "$MATE_HOME/state" "$TMP_ROOT/bin"
printf 'mate\n' > "$MATE_HOME/.fm-secondmate-home"
. "$ROOT/bin/fm-hc-secondmate-lib.sh"
fm_hc_secondmate_bind "$MATE_HOME" mate "$HC_SESSION:$MATE" || fail 'bind shell mate'
ln -s /bin/bash "$TMP_ROOT/bin/codex"
cat > "$TMP_ROOT/native-parent.sh" <<'SH'
#!/usr/bin/env bash
set -eu
bash "$TEST_ROOT/bin/fm-lock.sh"
. "$TEST_ROOT/bin/fm-backend.sh"
fm_backend_source hc
leaf=$(fm_backend_hc_create_task "$HC_SESSION" "${TEST_LEAF_LABEL:-fm-leaf}" "$TEST_WORK")
printf '%s\n' "$leaf" > "$TEST_WORK/leaf-address"
# Verify a real nested caller hint from this terminal as well. The native
# binding already proves this task-labelled supervisor, regardless of hint.
[ "$(fm_backend_hc_parent "$HC_SESSION")" = "$HC_TERMINAL_ID" ]
while [ ! -e "$TEST_WORK/end-mate" ]; do sleep 0.1; done
SH
printf -v driver 'env FM_HOME=%q FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= TEST_ROOT=%q TEST_WORK=%q FM_HC_BIN=%q FM_HC_SOCKET=%q HC_SESSION=%q FM_SUPERVISOR_BACKEND=hc FM_SUPERVISOR_TARGET=%q %q %q' \
  "$MATE_HOME" "$ROOT" "$WORK_DIR" "$FM_HC_BIN" "$FM_HC_SOCKET" "$HC_SESSION" "$HC_SESSION:$MATE" "$TMP_ROOT/bin/codex" "$TMP_ROOT/native-parent.sh"
fm_backend_hc_send_text_line "$HC_SESSION:$MATE" "$driver; exit" fm-mate || fail 'start native shell fixture'
wait_for 10 test -s "$WORK_DIR/leaf-address" || fail 'native shell fixture did not create leaf'
LEAF=$(cat "$WORK_DIR/leaf-address")
parent_is "$LEAF" "$MATE" || fail 'native leaf did not link to bound mate'
pass 'hc hierarchy: primary -> mate -> leaf nesting uses verified native home binding'
fm_backend_hc_get "$HC_SESSION:$LEAF" | jq -e '.name | test("^leaf-[0-9a-f]{8}$")' >/dev/null || fail 'real worker task name'

# A real program starting inside an unlabelled primary also corroborates its
# HC hint through ancestry, without an explicit parent override.
cat > "$TMP_ROOT/ambient-parent.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "$TEST_ROOT/bin/fm-backend.sh"
fm_backend_source hc
fm_backend_hc_create_task "$HC_SESSION" fm-ambient "$TEST_WORK" > "$TEST_WORK/ambient-address"
SH
printf -v driver 'env FM_HOME=%q TEST_ROOT=%q TEST_WORK=%q FM_HC_BIN=%q FM_HC_SOCKET=%q HC_SESSION=%q bash %q' \
  "$FM_HOME" "$ROOT" "$WORK_DIR" "$FM_HC_BIN" "$FM_HC_SOCKET" "$HC_SESSION" "$TMP_ROOT/ambient-parent.sh"
fm_backend_hc_cli "$HC_SESSION" send --json "$PARENT" -- "$driver" >/dev/null || fail 'ambient driver'
wait_for 10 test -s "$WORK_DIR/ambient-address" || fail 'ambient shell fixture did not create child'
AMBIENT=$(cat "$WORK_DIR/ambient-address")
parent_is "$AMBIENT" "$PARENT" || fail 'ancestor-verified caller did not link'
pass 'hc hierarchy: actual parent-terminal shell corroborates HC marker without explicit pins'

# Parent program exit and terminal removal must leave both levels running.
fm_backend_hc_cli "$HC_SESSION" send --json "$PARENT" -- exit >/dev/null || fail 'exit root program'
finished() { fm_backend_hc_get "$HC_SESSION:$1" | jq -e '.state == "finished"' >/dev/null; }
wait_for 10 finished "$PARENT" || fail 'root program did not finish'
fm_backend_hc_cli "$HC_SESSION" rm --json "$PARENT" >/dev/null || fail 'remove root terminal'
if ! parent_is "$MATE" "$PARENT" || ! parent_is "$LEAF" "$MATE" || ! parent_is "$AMBIENT" "$PARENT"; then
  fail 'descendant failed to outlive removed root'
fi
touch "$WORK_DIR/end-mate"
wait_for 10 finished "$MATE" || fail 'mate program did not finish'
fm_backend_hc_cli "$HC_SESSION" rm --json "$MATE" >/dev/null || fail 'remove mate terminal'
parent_is "$LEAF" "$MATE" || fail 'leaf failed to outlive removed mate'
pass 'hc hierarchy: children survive parent program exit and terminal removal at both levels'

# Recovery creates a replacement and new children use the current binding;
# existing independent children keep their original fixed protocol parent.
REPLACEMENT=$(fm_backend_hc_create_task "$HC_SESSION" fm-mate "$WORK_DIR" secondmate) || fail 'mate replacement'
assert_equals "$MATE_NAME" "$(fm_backend_hc_get "$HC_SESSION:$REPLACEMENT" | jq -r .name)" 'supervisor replacement keeps its name'
fm_hc_secondmate_bind "$MATE_HOME" mate "$HC_SESSION:$REPLACEMENT" || fail 'replacement binding'
rm "$WORK_DIR/leaf-address" "$WORK_DIR/end-mate"
printf -v driver 'env TEST_LEAF_LABEL=fm-leaf2 FM_HOME=%q FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= TEST_ROOT=%q TEST_WORK=%q FM_HC_BIN=%q FM_HC_SOCKET=%q HC_SESSION=%q FM_SUPERVISOR_BACKEND=hc FM_SUPERVISOR_TARGET=%q %q %q' \
  "$MATE_HOME" "$ROOT" "$WORK_DIR" "$FM_HC_BIN" "$FM_HC_SOCKET" "$HC_SESSION" "$HC_SESSION:$REPLACEMENT" "$TMP_ROOT/bin/codex" "$TMP_ROOT/native-parent.sh"
fm_backend_hc_send_text_line "$HC_SESSION:$REPLACEMENT" "$driver; exit" fm-mate || fail 'replacement fixture'
wait_for 10 test -s "$WORK_DIR/leaf-address" || fail 'replacement leaf'
NEW_LEAF=$(cat "$WORK_DIR/leaf-address")
if ! parent_is "$NEW_LEAF" "$REPLACEMENT" || ! parent_is "$LEAF" "$MATE"; then
  fail 'replacement changed live children or used old parent'
fi
if fm_backend_hc_create_task "$HC_SESSION" fm-mate "$WORK_DIR" >/dev/null 2>&1; then fail 'duplicate replacement'; fi
if FM_HC_PARENT_TARGET="$HC_SESSION:$MATE" FM_HC_PARENT_CORE_ID="$PARENT_CORE" \
  fm_backend_hc_create_task "$HC_SESSION" fm-missing-parent "$WORK_DIR" >/dev/null 2>&1; then fail 'missing explicit parent'; fi
if FM_HC_PARENT_TARGET="$HC_SESSION:$NEW_LEAF" FM_HC_PARENT_CORE_ID="$PARENT_CORE" \
  fm_backend_hc_create_task "$HC_SESSION" fm-foreign-parent "$WORK_DIR" >/dev/null 2>&1; then fail 'foreign task parent'; fi
pass 'hc hierarchy: replacement selects current supervisor, preserves old children and refuses duplicate/missing/foreign parents'
touch "$WORK_DIR/end-mate"
wait_for 10 finished "$REPLACEMENT" || fail 'replacement fixture did not exit'
FM_HOME="$MATE_HOME" fm_backend_hc_kill "$HC_SESSION:$LEAF" '' fm-leaf || fail 'close independent leaf'
# NEW_LEAF is owned by the scratch mate home, not the parent test home.
FM_HOME="$MATE_HOME" fm_backend_hc_kill "$HC_SESSION:$NEW_LEAF" '' fm-leaf2 || fail 'close replacement leaf'
fm_backend_hc_cli "$HC_SESSION" rm --json "$REPLACEMENT" >/dev/null || fail 'remove replacement'
fm_backend_kill hc "$HC_SESSION:$AMBIENT" fm-ambient || fail 'close ambient child'

# Names are presentation only. Distinct raw IDs and homes survive the same
# readable prefix; an unrelated terminal holding a derived name must block
# create atomically without becoming this task's endpoint.
NAMES=''
for raw in fm-Issue.Priority_Review fm-issue-priority-review fm-a-very-long-shared-prefix-task-one fm-a-very-long-shared-prefix-task-two; do
  a=$(fm_backend_hc_create_task "$HC_SESSION" "$raw" "$WORK_DIR") || fail 'normalized task create'
  n=$(fm_backend_hc_get "$HC_SESSION:$a" | jq -er '.name') || fail 'named task get'
  [[ "$n" =~ ^[a-z0-9][a-z0-9-]*-[0-9a-f]{8}$ ]] && [ "${#n}" -le 32 ] || fail 'invalid or overlong core name'
  NAMES="$NAMES$n
"
done
mkdir -p "$TMP_ROOT/other-home"
other=$(FM_HOME="$TMP_ROOT/other-home" fm_backend_hc_create_task "$HC_SESSION" fm-issue-priority-review "$WORK_DIR") || fail 'other home same task'
other_name=$(fm_backend_hc_get "$HC_SESSION:$other" | jq -er '.name') || fail 'other home name'
assert_equals 5 "$(printf '%s%s\n' "$NAMES" "$other_name" | sort -u | wc -l | tr -d ' ')" 'real names disambiguate normalization, truncation and home'
reserved=$(fm_backend_hc_task_name fm-reserved)
occupant=$(fm_backend_hc_cli "$HC_SESSION" run --json --bg --no-parent --outlive-parent --no-notify --name "$reserved" -- bash --noprofile --norc | jq -er .address) || fail 'reserve collision name'
if fm_backend_hc_create_task "$HC_SESSION" fm-reserved "$WORK_DIR" >"$TMP_ROOT/collision.out" 2>&1; then fail 'name collision accepted'; fi
fm_backend_hc_get "$HC_SESSION:$occupant" | jq -e '.state == "live" and .labels["firstmate.task"] == null' >/dev/null || fail 'collision adopted or damaged foreign terminal'
fm_backend_hc_cli "$HC_SESSION" kill --json "$occupant" >/dev/null || fail 'release name'
reused=$(fm_backend_hc_create_task "$HC_SESSION" fm-reserved "$WORK_DIR") || fail 'finished names must be reusable'
assert_equals "$reserved" "$(fm_backend_hc_get "$HC_SESSION:$reused" | jq -r .name)" 'replacement retains the name'
pass 'hc names: real-core readable role/task names, normalization/truncation/home uniqueness, atomic collision refusal and finished-name reuse'

LABEL=fm-smoke1
SES=$(fm_backend_hc_container_ensure) || fail "container_ensure failed"
assert_equals "$SES" "$HC_TEST_SES" "container_ensure names the lab session"
ADDR=$(fm_backend_hc_create_task "$SES" "$LABEL" "$WORK_DIR") || fail "create_task failed"
T="$SES:$ADDR"
fm_backend_target_exists hc "$T" "$LABEL" || fail "the new terminal must exist under its label"
pass "hc smoke: create_task started $T"

mkdir -p "$WORK_DIR/sub"
fm_backend_hc_send_text_line "$T" "cd sub" "$LABEL" || fail "send_text_line failed"
path_is_sub() { [ "$(fm_backend_hc_current_path "$T" "$LABEL")" = "$WORK_DIR/sub" ]; }
wait_for 10 path_is_sub || fail "current_path did not follow cd (got $(fm_backend_hc_current_path "$T" "$LABEL"))"
pass "hc smoke: current_path follows the shell's cwd"

fm_backend_hc_send_text_line "$T" "echo Smoke-Line-42" "$LABEL" || fail "send_text_line failed"
captured() { fm_backend_capture hc "$T" 50 "$LABEL" | grep -qx 'Smoke-Line-42'; }
wait_for 10 captured || fail "capture did not show the submitted command's output"
pass "hc smoke: send_text_line ran the command and capture shows its output"

verdict=$(fm_backend_hc_send_text_submit "$T" "echo Sub-Line-7" 1 0.4 0 "$LABEL")
case "$verdict" in
  empty|pending|pending-unproven|unknown) ;;
  *) fail "send_text_submit returned '$verdict', outside its vocabulary" ;;
esac
sub_captured() { fm_backend_capture hc "$T" 50 "$LABEL" | grep -qx 'Sub-Line-7'; }
wait_for 10 sub_captured || fail "send_text_submit's text never reached the terminal (verdict $verdict)"
pass "hc smoke: send_text_submit delivers through send --wait (verdict $verdict)"

assert_equals "$(fm_backend_agent_state hc "$T")" dead "an idle shell is dead"
STANDIN=$(fm_agent_standin "$TMP_ROOT/standin") || fail "no agent stand-in survives a foreign name here"
mkdir -p "$TMP_ROOT/bin/claude"
cp "$STANDIN" "$TMP_ROOT/bin/claude/claude"
fm_backend_hc_send_text_line "$T" "exec $TMP_ROOT/bin/claude/claude 600" "$LABEL" || fail "agent launch send failed"
is_alive() { [ "$(fm_backend_agent_state hc "$T")" = alive ]; }
wait_for 10 is_alive || fail "agent_state did not report the agent-named foreground (got $(fm_backend_agent_state hc "$T"))"
pass "hc smoke: agent_state reads dead for a shell and alive for an agent-named foreground"

fm_backend_kill hc "$T" || fail "kill failed"
assert_equals "$(fm_backend_agent_state hc "$T")" missing "a closed terminal is missing"
fm_backend_kill hc "$T" || fail "closing an already-closed terminal must be a silent success"
pass "hc smoke: kill closes and removes the terminal"
# Native remote homes take this same adapter through an existing socket only.
# Exercise the wire path against the isolated real core, including a nested
# child and independent lifetime. The original CLI coverage above stays intact.
export FM_HC_EXPECT_CORE=$PARENT_CORE
SES=$(fm_backend_hc_container_ensure) || fail 'pinned existing core readiness'
ADDR=$(FM_HC_REMOTE_SUPERVISOR=1 fm_backend_hc_create_task "$SES" fm-remote-mate "$WORK_DIR" secondmate) || fail 'pinned supervisor create'
T="$SES:$ADDR"
fm_backend_hc_get "$T" | jq -e '.parent == null and .die_with_parent == false' >/dev/null || fail 'remote supervisor must be standalone'
fm_backend_hc_send_text_line "$T" 'echo Pinned-Socket-42' fm-remote-mate || fail 'pinned send'
pinned_capture() { fm_backend_capture hc "$T" 50 fm-remote-mate | grep -qx Pinned-Socket-42; }
wait_for 10 pinned_capture || fail 'pinned read'
# The real remote control owner must use the same host-local home labels for
# route, capture and durable send as the creating delegate. This is a protocol
# and inbox smoke with a shell, not a claim about a credentialed Codex turn.
REMOTE_HOME="$TMP_ROOT/remote-home"
mkdir -p "$REMOTE_HOME/state/parent-route" "$REMOTE_HOME/bin" "$REMOTE_HOME/projects/scratch"
printf 'dirty remote work\n' > "$REMOTE_HOME/projects/scratch/uncommitted"
touch "$REMOTE_HOME/AGENTS.md"
printf 'remote-mate\n' > "$REMOTE_HOME/.fm-secondmate-home"
cat > "$REMOTE_HOME/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=remote
parent_host=spark
control_root=$FM_HOME_DIR
backend=hc
hc_session=$SES
hc_core_id=$PARENT_CORE
EOF
cat > "$REMOTE_HOME/state/parent-route/remote-mate.meta" <<EOF
window=$T
worktree=$REMOTE_HOME
project=$FM_HOME_DIR
endpoint_task_id=remote-mate
backend=hc
hc_session=$SES
hc_terminal=$ADDR
hc_core_id=$PARENT_CORE
kind=secondmate
harness=codex
home=$REMOTE_HOME
EOF
remote_control() { FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$FM_HOME_DIR" bash "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"; }
receipt=$(remote_control route remote-mate) || fail 'native remote receipt'
assert_contains "$receipt" "target=$T" 'receipt target'
assert_contains "$receipt" "hc_core_id=$PARENT_CORE" 'receipt permanent core'
remote_control capture remote-mate 30 | grep -qx Pinned-Socket-42 || fail 'native remote capture owner'
remote_control send remote-mate 'request [corr=0123456789abcdef]: isolated durable steer' >/dev/null 2>&1 || fail 'native durable send'
remote_control send remote-mate 'request [corr=0123456789abcdef]: isolated durable steer' >/dev/null 2>&1 || fail 'native exact resend'
assert_equals 1 "$(find "$REMOTE_HOME/state/parent-route/remote-mate.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" 'remote same-body resend is idempotent'
cp "$REMOTE_HOME/.fm-secondmate-parent" "$TMP_ROOT/parent-before"
sed 's/^hc_core_id=.*/hc_core_id=wrong-core/' "$TMP_ROOT/parent-before" > "$REMOTE_HOME/.fm-secondmate-parent"
if remote_control capture remote-mate 10 >/dev/null 2>&1; then fail 'remote owner accepted changed core'; fi
cp "$TMP_ROOT/parent-before" "$REMOTE_HOME/.fm-secondmate-parent"
assert_equals 'dirty remote work' "$(cat "$REMOTE_HOME/projects/scratch/uncommitted")" 'remote refusals preserve work'
pass 'native remote control: exact receipt, consistent capture owner, durable deduplicated inbox and wrong-core preservation'

# Explicit task-labelled parents need the native home binding; plain shell
# primary for this transport-only child proof retains the same permanent core.
PINNED_PARENT=$(fm_backend_hc_cli "$SES" run --bg --json --name pinned-primary --cwd "$WORK_DIR" --no-parent --outlive-parent --no-notify | jq -er .address) || fail 'pinned shell parent'
CHILD=$(FM_HC_PARENT_TARGET="$SES:$PINNED_PARENT" FM_HC_PARENT_CORE_ID="$PARENT_CORE" \
  fm_backend_hc_create_task "$SES" fm-pinned-child "$WORK_DIR") || fail 'pinned child create'
parent_is "$CHILD" "$PINNED_PARENT" || fail 'pinned parent parameters'
if FM_HC_EXPECT_CORE=wrong-core fm_backend_hc_kill "$T" '' fm-remote-mate; then fail 'wrong core accepted'; fi
if FM_HOME="$TMP_ROOT/other-home" fm_backend_hc_kill "$T" '' fm-remote-mate; then fail 'wrong home accepted'; fi
fm_backend_target_exists hc "$T" fm-remote-mate || fail 'refusals damaged endpoint'
fm_backend_kill hc "$T" || fail 'pinned close'
fm_backend_hc_cli "$SES" kill --json "$PINNED_PARENT" >/dev/null || fail 'pinned parent close'
fm_backend_hc_cli "$SES" rm --json "$PINNED_PARENT" >/dev/null || fail 'pinned parent remove'
fm_backend_target_exists hc "$SES:$CHILD" fm-pinned-child || fail 'pinned close harmed independent child'
fm_backend_kill hc "$SES:$CHILD" || fail 'pinned child close'
unset FM_HC_EXPECT_CORE
pass 'native existing-socket path: real-core create, parent, send/read, wrong-core/home refusal, close and independent child'
echo FM_TEST_COMPLETE
