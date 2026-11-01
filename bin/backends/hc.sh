#!/usr/bin/env bash
# bin/backends/hc.sh - the herdr-core (`hc`) session-provider adapter (EXPERIMENTAL).
#
# herdr-core is the terminal core under Herdr.app: a per-user daemon that keeps
# terminals alive and answers a JSON CLI (`hc run|get|ls|read|send|keys|kill|rm`).
# It is not Herdr 1 (`herdr`, bin/backends/herdr.sh); the two share no socket,
# no id space, and no CLI. Like tmux, hc is a session provider ONLY: the
# worktree provider stays treehouse, driven by fm-spawn.sh through the same
# send/current-path primitives it uses for tmux. docs/hc-backend.md owns the
# user-facing mechanics and limits; this header owns the adapter's design.
# Sourced only through bin/fm-backend.sh's fm_backend_source in normal
# operation; the unit tests source it directly.
#
# Selection is explicit-only: `--backend hc`, FM_BACKEND=hc, or config/backend.
# hc stamps HC_TERMINAL_ID into every process it starts, including a tmux or
# Herdr 1 client started inside an hc terminal, so an inherited marker never
# proves the captain chose hc and fm_backend_detect never reads it.
#
# Target string shape: "<session>:<address>". <session> is the hc session the
# terminal lives in (HC_SESSION at spawn time, `default` when unset) and
# <address> is hc's own terminal address (`t7`). Every call re-exports exactly
# that HC_SESSION, so a target keeps naming the core it was created on even when
# the caller's ambient HC_SESSION differs. Measured on hc 0.1.13: HC_SESSION
# wins over an inherited HC_TERMINAL_SOCKET, so a firstmate running inside an hc
# terminal still reaches the recorded core.
#
# Identity: each task terminal carries the labels firstmate.task=<window-label>
# and firstmate.home=<hometag> (the physical FM_HOME, via
# bin/fm-backend-hometag-lib.sh). Operations refuse foreign home labels and,
# when given an expected task label, require it too, so a
# recorded address can never steer input into another home's terminal.
# Human-facing names are separate from ownership: create_task derives a readable
# slug from the task id and kind (secondmates append "supervisor"), with a
# checksum of the full home-scoped label. The 23-byte prefix plus dash and
# 8-hex checksum fits hc's 32-byte lowercase name limit. Normalization and
# truncation retain distinct suffixes for different raw labels/homes; any
# remaining collision is refused atomically by hc, never adopted or retried
# without a name. Finished terminals release their names for replacements.
# Herdr.app's nested agent rows prefer this core name over template/program,
# not the terminal title. Names are creation-only; existing endpoints are
# never restarted or rewritten just to rename them.
#
# Visibility in Herdr.app: the app shows a terminal that carries
# herdr.space=<id> and herdr.tab=<id> labels, and an unknown id becomes a new
# space or tab. create_task sets herdr.space=FM_HC_SPACE (default
# fm-<hometag>) and herdr.tab=<scoped label>, so a home's tasks group in one
# space with one tab each. Naming the space needs the app window and is not done.
#
# Measured limits on hc 0.1.13 and 0.1.14 (docs/hc-backend.md "Limits"):
#   - `hc send` always presses Enter after pasting. There is no paste without
#     submit, so hc cannot type without submitting. `hc send --wait` reports
#     the turn the send started natively, which is what send_text_submit reads.
#   - hc reports one foreground process per terminal (`foreground` in
#     `hc get`), not a process group; when that process is a launcher,
#     agent_state also reads the rest of its process group from local `ps`.
#   - hc has no event push this adapter consumes; supervision polls like tmux.
#
# Binary gate: FM_HC_BIN wins, else `herdr-core`, else `hc` (the release
# asset's name and its CLI alias). `<bin> --version` must report `hc x.y.z`
# at or above FM_BACKEND_HC_MIN_VERSION, and container_ensure additionally
# proves the session speaks protocol generation 1 through `hello`.

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-backend-hometag-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-agent-process-lib.sh"

# The verified floor: the oldest herdr-core release every adapter surface
# (including `send --wait` and the `hello` handshake) was exercised against.
FM_BACKEND_HC_MIN_VERSION=0.1.14

# The one protocol generation this adapter speaks.
FM_BACKEND_HC_GENERATION=1

# The hc session a new task is created on: the caller's HC_SESSION, else hc's
# own default session name.
fm_backend_hc_session() {
  printf '%s' "${HC_SESSION:-default}"
}

# fm_backend_hc_bin: the resolved herdr-core binary path, or failure. The
# release asset's own name is `herdr-core`; `hc` is its CLI alias. FM_HC_BIN
# wins so tests and the lab can pin a build; version_check still proves the
# resolved file is herdr-core and no other tool.
fm_backend_hc_bin() {
  if [ -n "${FM_HC_BIN:-}" ]; then
    [ -x "$FM_HC_BIN" ] || return 1
    printf '%s' "$FM_HC_BIN"
    return 0
  fi
  command -v herdr-core 2>/dev/null || command -v hc 2>/dev/null
}

# fm_backend_hc_version_check: refuse loudly on a missing, misnamed, or
# older-than-verified binary. `<bin> --version` must print `hc x.y.z`.
fm_backend_hc_version_check() {
  local bin raw ver major rest minor patch cur min fmaj fmin fpat
  bin=$(fm_backend_hc_bin) || {
    echo "error: backend=hc selected but no 'herdr-core' or 'hc' binary was found on PATH (install Herdr Core per docs/hc-backend.md or set FM_HC_BIN)" >&2
    return 1
  }
  raw=$("$bin" --version 2>/dev/null) \
    || { echo "error: '$bin --version' failed; is herdr-core installed correctly?" >&2; return 1; }
  case "$raw" in
    'hc '[0-9]*.[0-9]*.[0-9]*)
      ver=${raw#hc }
      ver=${ver%%[[:space:]]*}
      ;;
    *)
      echo "error: expected 'hc x.y.z' from '$bin --version' but got '$raw'; refusing to use a binary that is not Herdr Core" >&2
      return 1
      ;;
  esac
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  case "$rest" in
    *.*) patch=${rest#*.} ;;
    *) patch=0 ;;
  esac
  patch=${patch%%[^0-9]*}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  case "$patch" in ''|*[!0-9]*) patch=0 ;; esac
  IFS=. read -r fmaj fmin fpat <<EOF
$FM_BACKEND_HC_MIN_VERSION
EOF
  cur=$((major * 1000000 + minor * 1000 + patch))
  min=$((fmaj * 1000000 + fmin * 1000 + fpat))
  if [ "$cur" -lt "$min" ]; then
    echo "error: herdr-core $ver is older than the verified minimum $FM_BACKEND_HC_MIN_VERSION; update herdr-core before using backend=hc" >&2
    return 1
  fi
  return 0
}

# A native remote home pins its destination core in its seeded parent record.
# The host-local control delegate passes the same pin explicitly. Ordinary local
# homes retain CLI behavior; a native pin uses existing-only protocol operations
# with the hello identity proved on the SAME socket as the requested operation.
fm_backend_hc_expected_core() { # <session> -> core id or empty for legacy/local
  if [ -e "$FM_HOME/.fm-secondmate-parent" ] || [ -L "$FM_HOME/.fm-secondmate-parent" ]; then
    # shellcheck source=bin/fm-secondmate-parent-lib.sh
    . "$FM_BACKEND_LIB_DIR/fm-secondmate-parent-lib.sh"
    fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || return 1
    if [ "$FM_SECONDMATE_PARENT_BACKEND" = hc ]; then
      [ "$1" = "$FM_SECONDMATE_PARENT_HC_SESSION" ] || return 1
      [ "${FM_HC_EXPECT_CORE-$FM_SECONDMATE_PARENT_HC_CORE}" = "$FM_SECONDMATE_PARENT_HC_CORE" ] || return 1
      printf '%s' "$FM_SECONDMATE_PARENT_HC_CORE"
      return 0
    fi
  fi
  if [ "${FM_HC_EXPECT_CORE+x}" = x ]; then
    [[ "$FM_HC_EXPECT_CORE" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    printf '%s' "$FM_HC_EXPECT_CORE"
  fi
  return 0
}

# fm_backend_hc_env_run: run the resolved binary with exactly <session>'s env
# pins. Ambient HC_TERMINAL_* routing markers are always stripped. An
# inherited HC_SOCKET is stripped because hc lets it win over HC_SESSION;
# FM_HC_SOCKET is the deliberate pin used by tests and the lab instead.
fm_backend_hc_env_run() {  # <session> <args...>
  local session=$1 bin core
  shift
  bin=$(fm_backend_hc_bin) || {
    echo "error: backend=hc selected but no 'herdr-core' or 'hc' binary was found on PATH (install Herdr Core per docs/hc-backend.md or set FM_HC_BIN)" >&2
    return 1
  }
  core=$(fm_backend_hc_expected_core "$session") || return 1
  if [ -n "$core" ]; then
    python3 "$FM_BACKEND_LIB_DIR/fm-hc-screen.py" --cli "$session" "$core" "$@"
    return $?
  fi
  if [ -n "${FM_HC_SOCKET:-}" ]; then
    env -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE \
      HC_SESSION="$session" HC_SOCKET="$FM_HC_SOCKET" "$bin" "$@"
  else
    env -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE -u HC_SOCKET \
      HC_SESSION="$session" "$bin" "$@"
  fi
}

# fm_backend_hc_cli: run hc against exactly <session>.
# An invalid or empty session is refused: an empty HC_SESSION would let hc
# fall back to whatever core the caller's environment names. stdin is
# detached so hc never consumes a caller's loop input.
fm_backend_hc_cli() {  # <session> <args...>
  local session=$1
  shift
  fm_backend_hc_atom_valid "$session" || { echo "error: refusing hc session '$session'" >&2; return 1; }
  fm_backend_hc_env_run "$session" "$@" </dev/null
}

fm_backend_hc_atom_valid() {  # <value>
  case "$1" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_backend_hc_address_valid() {  # <value>
  case "$1" in
    t*) ;;
    *) return 1 ;;
  esac
  case "${1#t}" in
    ''|*[!0123456789abcdefghijklmnopqrstuvwxyz]*) return 1 ;;
  esac
}

# fm_backend_hc_parse_target: split "<session>:<address>" into
# FM_BACKEND_HC_SESSION and FM_BACKEND_HC_ADDRESS, or return 1.
fm_backend_hc_parse_target() {  # <target>
  local target=${1:-}
  FM_BACKEND_HC_SESSION=
  FM_BACKEND_HC_ADDRESS=
  case "$target" in
    *:*:*|:*|*:) return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  fm_backend_hc_atom_valid "${target%%:*}" || return 1
  fm_backend_hc_address_valid "${target#*:}" || return 1
  FM_BACKEND_HC_SESSION=${target%%:*}
  FM_BACKEND_HC_ADDRESS=${target#*:}
}

fm_backend_hc_scoped_label() {  # <window-label>
  printf '%s-%s' "$(fm_backend_hc_hometag)" "$1"
}

# Runtime ownership follows the operational home even when several homes use
# one tracked code root. Keep other backends' existing tag derivation unchanged.
fm_backend_hc_hometag() {
  FM_ROOT=$FM_HOME fm_backend_hometag
}

fm_backend_hc_expected_labels() { # <target> [expected-task]; prints home<TAB>task
  local id meta
  case "${2:-}" in
    fm-*)
      id=${2#fm-}
      case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
      meta="${FM_STATE_OVERRIDE:-$FM_HOME/state}/$id.meta"
      if [ -e "$meta" ] || [ -L "$meta" ]; then
        # Includes inbox re-rings: a reused address on a replacement core must
        # never receive input just because it copied this home's labels.
        if grep -qE '^(kind=secondmate|hc_core_id=)' "$meta"; then
          fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 \
            && [ "$FM_BACKEND_VALIDATED_BACKEND" = hc ] \
            && fm_backend_hc_record_matches_core "$meta" || return 1
        fi
      fi
      ;;
  esac
  if [ -z "${2:-}" ] && [ -e "$FM_HOME/state/.hc-secondmate.json" ] \
    && [ "$(jq -r '.target // empty' "$FM_HOME/state/.hc-secondmate.json" 2>/dev/null)" = "$1" ]; then
    # A secondmate's own supervisor endpoint is labelled by its parent home.
    # Only its live, ancestry-bound home lock may authorize that exception.
    # shellcheck source=bin/fm-hc-secondmate-lib.sh
    . "$FM_BACKEND_LIB_DIR/fm-hc-secondmate-lib.sh"
    fm_hc_secondmate_self_identity "$FM_HOME" "$1" && return 0
    return 1
  fi
  printf '%s\t%s' "$(fm_backend_hc_hometag)" "${2:-*}"
}

# fm_backend_hc_get: `hc get --json` of the parsed target. Status 3 is hc's
# structured not_found; any other failure is an unreadable core.
fm_backend_hc_get() {  # <target>
  fm_backend_hc_parse_target "$1" || return 1
  fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" get --json "$FM_BACKEND_HC_ADDRESS" 2>/dev/null
}

# fm_backend_hc_endpoint_state: classify <target> against a fresh `hc get`.
# Prints exactly one of: ready, finished, absent, foreign, unreadable. A
# terminal is `foreign` when [expected-label] is given and its labels do not
# carry this home's labels for it; `*` accepts any task label of this home.
fm_backend_hc_endpoint_state() {  # <target> [expected-label]
  local target=$1 expected=${2:-} json rc
  fm_backend_hc_parse_target "$target" || { printf 'unreadable'; return 0; }
  if json=$(fm_backend_hc_get "$target"); then rc=0; else rc=$?; fi
  if [ "$rc" -eq 3 ]; then printf 'absent'; return 0; fi
  [ "$rc" -eq 0 ] || { printf 'unreadable'; return 0; }
  fm_backend_hc_snapshot_state "$target" "$expected" "$json"
}

fm_backend_hc_snapshot_state() { # <target> <expected-label> <get-json>
  local target=$1 expected=$2 json=$3 fields state task home identity expected_home
  printf '%s' "$json" | jq -e --arg addr "${target#*:}" '.address == $addr
    and (.labels | type == "object") and (.state | type == "string")' >/dev/null 2>&1 \
    || { printf 'unreadable'; return 0; }
  fields=$(printf '%s' "$json" | jq -r '[.state // "", .labels["firstmate.task"] // "", .labels["firstmate.home"] // ""] | @tsv' 2>/dev/null) || {
    printf 'unreadable'
    return 0
  }
  IFS=$'\t' read -r state task home <<EOF
$fields
EOF
  identity=$(fm_backend_hc_expected_labels "$target" "$expected") || { printf 'foreign'; return 0; }
  expected_home=${identity%%$'\t'*}
  expected=${identity#*$'\t'}
  if { [ "$home" != "$expected_home" ] \
    || { [ "$expected" = '*' ] && [ -z "$task" ]; } \
    || { [ "$expected" != '*' ] && [ "$task" != "$expected" ]; }; }; then
    printf 'foreign'
    return 0
  fi
  case "$state" in
    live) printf 'ready' ;;
    finished) printf 'finished' ;;
    *) printf 'unreadable' ;;
  esac
}

# Also leaves FM_BACKEND_HC_SESSION/ADDRESS set in the caller's shell, which
# the command-substituted state read above cannot do.
fm_backend_hc_target_ready() {  # <target> [expected-label]
  [ "$(fm_backend_hc_endpoint_state "$1" "${2:-}")" = ready ] && fm_backend_hc_parse_target "$1"
}

# fm_backend_hc_hello: the generation handshake for <session> over `hc
# connect`. Prints the negotiated generation, nothing on failure.
fm_backend_hc_hello_json() { # <session>; normalized hello result
  local core
  core=$(fm_backend_hc_expected_core "$1") || return 1
  if [ -n "$core" ]; then
    python3 "$FM_BACKEND_LIB_DIR/fm-hc-screen.py" --cli "$1" "$core" hello
  else
    printf '{"jsonrpc":"2.0","method":"hello","params":{"generation":1},"id":1}\n' \
      | fm_backend_hc_env_run "$1" connect --session "$1" 2>/dev/null | jq -e '.result'
  fi
}

fm_backend_hc_hello() { # <session>
  fm_backend_hc_hello_json "$1" | jq -er '.generation'
}

# Permanent identity is checked on every pinned operation, not just at spawn.
fm_backend_hc_core_id() { # <session>
  fm_backend_hc_hello_json "$1" | jq -er 'select(.generation == 1) | .core.id |
    select(type == "string" and test("^[A-Za-z0-9_-]+$"))'
}

fm_backend_hc_record_matches_core() { # <meta>
  local recorded session current
  recorded=$(fm_backend_meta_exact_value "$1" hc_core_id) || return 1
  session=$(fm_backend_meta_exact_value "$1" hc_session) || return 1
  fm_backend_hc_atom_valid "$recorded" && fm_backend_hc_atom_valid "$session" || return 1
  current=$(fm_backend_hc_core_id "$session") || return 1
  [ "$recorded" = "$current" ]
}

fm_backend_hc_secondmate_runtime_check() {
  local FM_BACKEND_HC_MIN_VERSION=0.1.16
  fm_backend_hc_version_check || return 1
  command -v python3 >/dev/null 2>&1 || { echo "error: native hc secondmate control requires Python 3 for read-only styled observation" >&2; return 1; }
}

# A displayed Codex client may otherwise reuse a daemon outside this terminal,
# with that daemon's home and routing environment. hc requires local execution.
fm_backend_hc_codex_launch_check() {
  local help
  help=$(codex --help 2>/dev/null) || return 1
  printf '%s\n' "$help" | grep -q -- '--no-daemon' || {
    echo "error: hc requires a Codex CLI supporting --no-daemon so its tools stay inside the native terminal" >&2
    return 1
  }
}

# fm_backend_hc_container_ensure: prove the binary is herdr-core at the
# verified floor, make sure the session's core answers (hc starts its own
# core on first use) and speaks protocol generation 1, then print the
# session name.
fm_backend_hc_container_ensure() {
  local session gen
  fm_backend_hc_version_check || return 1
  command -v jq >/dev/null 2>&1 \
    || { echo "error: backend=hc selected but 'jq' is not installed (required to parse hc's JSON output)" >&2; return 1; }
  session=$(fm_backend_hc_session)
  fm_backend_hc_atom_valid "$session" || { echo "error: refusing hc session name '$session'" >&2; return 1; }
  fm_backend_hc_cli "$session" server status --json >/dev/null 2>&1 \
    || { echo "error: 'hc server status' failed for session '$session'; is herdr-core installed and startable?" >&2; return 1; }
  gen=$(fm_backend_hc_hello "$session") || {
    echo "error: herdr-core session '$session' did not answer the hello handshake; is the core reachable?" >&2
    return 1
  }
  if [ "$gen" != "$FM_BACKEND_HC_GENERATION" ]; then
    echo "error: herdr-core session '$session' speaks protocol generation '$gen', but this adapter requires generation $FM_BACKEND_HC_GENERATION" >&2
    return 1
  fi
  printf '%s' "$session"
}

# Native parent selection (only for new endpoints, including replacements):
# - A native secondmate's own state/.hc-secondmate.json wins, subject to its
#   existing live home-lock, terminal-incarnation, core and parent-label proof.
# - Outside that binding, an operator may set FM_HC_PARENT_TARGET=session:t7
#   and FM_HC_PARENT_CORE_ID=<hello core.id> together for this invocation.
#   FM_SUPERVISOR_BACKEND=hc with FM_SUPERVISOR_TARGET is also an explicit
#   request, requiring the same core pin. Unlabelled primary terminals are
#   allowed; task-labelled or foreign-home terminals require the native binding.
# - Otherwise HC_TERMINAL_ID is only a hint: a live terminal on the selected
#   core must have a kernel pid in this caller's ancestry and no task labels.
#   Stale/foreign ambient hints fall back to standalone, never endpoint scans.
# Explicit/bound requests fail closed on missing, finished, foreign, wrong-core
# or wrong-session targets. With no proved parent use --no-parent. All launches
# keep --outlive-parent --no-notify: protocol hierarchy is not Unix ancestry or
# lifecycle authority. Existing children are never reparented or terminated.
fm_backend_hc_parent() { # <session> -> address, or empty for standalone
  local session=$1 target='' core='' json='' binding="$FM_HOME/state/.hc-secondmate.json"
  local native=0 explicit=0 pid candidate hops=0 home
  [ "${FM_HC_REMOTE_SUPERVISOR:-0}" != 1 ] || return 0
  fm_backend_hc_atom_valid "$session" || { echo "error: invalid hc parent session '$session'" >&2; return 1; }
  if [ -e "$binding" ] || [ -L "$binding" ]; then
    [ -f "$binding" ] && [ ! -L "$binding" ] || { echo "error: invalid native hc parent binding" >&2; return 1; }
    if ! target=$(jq -er '.target | select(type == "string")' "$binding") \
      || ! core=$(jq -er '.core | select(type == "string" and length > 0)' "$binding"); then
      echo "error: malformed native hc parent binding '$binding'" >&2; return 1
    fi
    native=1
  fi
  if [ "${FM_HC_PARENT_TARGET+x}${FM_HC_PARENT_CORE_ID+x}" != '' ]; then
    [ -n "${FM_HC_PARENT_TARGET:-}" ] && [ -n "${FM_HC_PARENT_CORE_ID:-}" ] || {
      echo "error: set both FM_HC_PARENT_TARGET and FM_HC_PARENT_CORE_ID for an explicit hc parent" >&2; return 1;
    }
    if [ "$native" = 1 ] && { [ "$target" != "$FM_HC_PARENT_TARGET" ] || [ "$core" != "$FM_HC_PARENT_CORE_ID" ]; }; then
      echo "error: explicit hc parent conflicts with this native supervisor binding" >&2; return 1
    fi
    target=$FM_HC_PARENT_TARGET core=$FM_HC_PARENT_CORE_ID explicit=1
  fi
  if [ "${FM_SUPERVISOR_BACKEND:-}" = hc ]; then
    if [ -n "$target" ] && [ "$target" != "${FM_SUPERVISOR_TARGET:-}" ]; then
      echo "error: hc parent conflicts with FM_SUPERVISOR_TARGET" >&2; return 1
    fi
    target=${FM_SUPERVISOR_TARGET:-} explicit=1
    [ -n "$target" ] && [ -n "$core" ] || {
      echo "error: explicit hc supervisor needs a native binding or FM_HC_PARENT_TARGET and FM_HC_PARENT_CORE_ID" >&2; return 1;
    }
  fi
  if [ "$native" = 0 ] && [ "$explicit" = 0 ]; then
    fm_backend_hc_address_valid "${HC_TERMINAL_ID:-}" || return 0
    target="$session:$HC_TERMINAL_ID"
  fi
  fm_backend_hc_parse_target "$target" && [ "$FM_BACKEND_HC_SESSION" = "$session" ] || {
    echo "error: invalid hc parent '$target' for session '$session'" >&2; return 1;
  }
  if json=$(fm_backend_hc_get "$target") && printf '%s' "$json" | jq -e --arg a "${target#*:}" '
    .address == $a and .state == "live" and (.labels | type == "object")' >/dev/null; then
    if [ "$native" = 1 ]; then
      [ "$(fm_backend_hc_endpoint_state "$target")" = ready ] || {
        echo "error: native hc parent ownership is not verified for '$target'" >&2; return 1;
      }
    else
      home=$(fm_backend_hc_hometag)
      if ! printf '%s' "$json" | jq -e --arg h "$home" '
        (.labels["firstmate.home"] == null or .labels["firstmate.home"] == $h)
        and .labels["firstmate.task"] == null' >/dev/null; then
        if [ "$explicit" = 0 ]; then return 0; fi
        echo "error: hc parent '$target' has foreign home or task ownership" >&2; return 1
      fi
    fi
    if [ "$native" = 1 ] || [ "$explicit" = 1 ]; then
      [ "$(fm_backend_hc_core_id "$session")" = "$core" ] || {
        echo "error: hc parent '$target' core identity does not match the requested pin" >&2; return 1;
      }
    else
      pid=$(printf '%s' "$json" | jq -er '.pid | select(type == "number" and . > 1)') || return 0
      # $$ remains the invoking shell across command substitutions. Only a
      # real ancestor proves that a tool did not inherit another caller's hint.
      candidate=$$
      while [ "$candidate" != "$pid" ]; do
        case "$candidate" in ''|0|1|*[!0-9]*) return 0 ;; esac
        [ "$hops" -lt 64 ] || return 0
        candidate=$(LC_ALL=C ps -o ppid= -p "$candidate" 2>/dev/null | tr -d ' ') || return 0
        hops=$((hops + 1))
      done
    fi
    printf '%s' "${target#*:}"
    return 0
  fi
  if [ "$native" = 0 ] && [ "$explicit" = 0 ]; then return 0; fi
  echo "error: hc parent '$target' is missing, finished, or unreadable" >&2
  return 1
}

# Presentation only: labels and validated addresses remain the identity boundary.
fm_backend_hc_task_name() { # <window-label> [kind]
  local label=$1 kind=${2:-ship} slug checksum
  slug=${label#fm-}
  slug=$(printf '%s' "$slug" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cs 'a-z0-9' '-' | cut -c1-23 | sed 's/^-*//; s/-*$//')
  if [ "$kind" = secondmate ]; then
    slug=$(printf '%s' "$slug" | cut -c1-12 | sed 's/-*$//')
    [ -n "$slug" ] || slug=task
    slug="$slug-supervisor"
  fi
  [ -n "$slug" ] || slug=task
  checksum=$(printf '%s' "$(fm_backend_hc_scoped_label "$label")" | cksum | awk '{printf "%08x", $1}')
  printf '%s-%s' "$slug" "$checksum"
}

# Start a login shell in <cwd> for <window-label>, refusing a live duplicate
# in this home. Prints the address; parent selection above never changes labels.
fm_backend_hc_create_task() {  # <session> <window-label> <cwd> [kind]
  local session=$1 label=$2 cwd=$3 kind=${4:-ship} home scoped dup out address parent name
  local parent_args=(--no-parent)
  parent=$(fm_backend_hc_parent "$session") || return 1
  [ -z "$parent" ] || parent_args=(--parent "$parent")
  home=$(fm_backend_hc_hometag)
  scoped=$(fm_backend_hc_scoped_label "$label")
  name=$(fm_backend_hc_task_name "$label" "$kind") || return 1
  dup=$(fm_backend_hc_cli "$session" ls --json --label "firstmate.task=$label" --label "firstmate.home=$home" 2>/dev/null) \
    || { echo "error: 'hc ls' failed for session '$session'; cannot create $label" >&2; return 1; }
  printf '%s' "$dup" | jq -e 'type == "object" and (.terminals | type == "array")' >/dev/null 2>&1 \
    || { echo "error: malformed hc inventory; refusing duplicate-unsafe create" >&2; return 1; }
  if [ -n "$(printf '%s' "$dup" | jq -r '.terminals[]?.address' 2>/dev/null)" ]; then
    echo "error: hc terminal for $label already exists in session '$session'" >&2
    return 1
  fi
  out=$(fm_backend_hc_cli "$session" run --bg --json "${parent_args[@]}" --outlive-parent --no-notify \
    --cwd "$cwd" --name "$name" \
    --label "firstmate.task=$label" --label "firstmate.home=$home" \
    --label "herdr.space=${FM_HC_SPACE:-fm-$home}" --label "herdr.tab=$scoped" 2>&1) \
    || { echo "error: hc run failed for $label: $out" >&2; return 1; }
  address=$(printf '%s' "$out" | jq -r '.address // empty' 2>/dev/null)
  fm_backend_hc_address_valid "$address" || { echo "error: hc run did not return a terminal address for $label (got: $out)" >&2; return 1; }
  printf '%s\n' "$address"
}

# fm_backend_hc_capture: the screen plus <lines> of history, the same window
# tmux's `capture-pane -S -<lines>` returns.
fm_backend_hc_capture() {  # <target> <lines> [expected-label]
  local lines=${2:-200}
  fm_backend_hc_target_ready "$1" "${3:-}" || return 1
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" read --lines "$lines" "$FM_BACKEND_HC_ADDRESS" 2>/dev/null
}

# fm_backend_hc_visible_capture: the screen only (`--lines 0`).
fm_backend_hc_visible_capture() {  # <target> [expected-label]
  fm_backend_hc_target_ready "$1" "${2:-}" || return 1
  fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" read --lines 0 "$FM_BACKEND_HC_ADDRESS" 2>/dev/null
}

# fm_backend_hc_normalize_key: firstmate's key vocabulary onto hc key names.
fm_backend_hc_normalize_key() {  # <key>
  case "$1" in
    Enter|enter|C-m) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'esc' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'ctrl+c' ;;
    C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u) printf 'ctrl+u' ;;
    Up) printf 'up' ;;
    Down) printf 'down' ;;
    Tab) printf 'tab' ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_backend_hc_send_key() {  # <target> <key> [expected-label]
  fm_backend_hc_target_ready "$1" "${3:-}" || return 1
  fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" keys --json "$FM_BACKEND_HC_ADDRESS" \
    -- "$(fm_backend_hc_normalize_key "$2")" >/dev/null 2>&1
}

# fm_backend_hc_send_text_line: paste one line and submit it (`hc send`). The
# `--` delimiter keeps flag-looking text from being parsed as options.
fm_backend_hc_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_hc_target_ready "$1" "${3:-}" || return 1
  fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" send --json "$FM_BACKEND_HC_ADDRESS" -- "$2" >/dev/null 2>&1
}

fm_backend_hc_current_path() {  # <target> [expected-label]
  local json
  fm_backend_hc_target_ready "$1" "${2:-}" || return 0
  json=$(fm_backend_hc_get "$1") || return 0
  printf '%s' "$json" | jq -r '.foreground.cwd // .cwd // empty' 2>/dev/null
}

fm_backend_hc_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

fm_backend_hc_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict caps identity expected_home expected_task core
  caps=$(fm_backend_hc_composer_caps)
  if fm_backend_hc_target_ready "$1" "${2:-}" \
    && identity=$(fm_backend_hc_expected_labels "$1" "${2:-}") \
    && expected_home=${identity%%$'\t'*} && expected_task=${identity#*$'\t'} \
    && [ "$expected_task" != '*' ] \
    && core=$(fm_backend_hc_expected_core "$FM_BACKEND_HC_SESSION") \
    && cap=$(if [ -n "$core" ]; then export FM_HC_EXPECT_CORE="$core"; fi; python3 "$FM_BACKEND_LIB_DIR/fm-hc-screen.py" "$(fm_backend_hc_bin)" \
      "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_ADDRESS" "$expected_home" "$expected_task" 2>/dev/null); then
    caps=$(printf 'styled=1\ncursor=0\nidentity=0\n')
  else
    cap=$(fm_backend_hc_visible_capture "$1" "${2:-}") || { printf 'unknown'; return 0; }
  fi
  verdict=$(fm_composer_classify_screen "$caps" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_hc_send_text_submit: one `hc send --wait`, which pastes, presses
# Enter, and reports the turn it started. Echoes
# empty|pending|pending-unproven|unknown|send-failed, a subset of the
# proof-carrying submit vocabulary.
#
# A started turn or a still-working wait confirms the submit natively, which
# no composer text can fake. A program that never reports status answers
# started:null once the bounded wait times out; the send still typed and
# entered, so the verdict falls back to the composer screen, and only a
# proven pending composer gets Enter retries through the shared loop. A
# blocked terminal refuses with exit 9 before typing - unknown, with a
# diagnostic and no retries, never forced. The other structured refusals
# (3 not_found, 11 finished) and any other failure are send-failed.
fm_backend_hc_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected=${6:-}
  local wait_secs out rc started wait_status verdict
  case "$retries" in ''|*[!0-9]*) retries=1 ;; esac
  case "$sleep_s" in ''|*[!0-9.]*) sleep_s=0.4 ;; esac
  case "$settle" in ''|*[!0-9.]*) settle=0 ;; esac
  fm_backend_hc_target_ready "$target" "$expected" || { printf 'send-failed'; return 0; }
  wait_secs=$(awk -v r="$retries" -v s="$sleep_s" 'BEGIN { v = r * s; if (v < 1) v = 1; printf "%d", (v == int(v) ? v : int(v) + 1) }' 2>/dev/null)
  case "$wait_secs" in ''|*[!0-9]*|0) wait_secs=1 ;; esac
  out=$(fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" send --json "$FM_BACKEND_HC_ADDRESS" \
    --wait --timeout "$wait_secs" -- "$text" 2>&1)
  rc=$?
  case "$rc" in
    0) ;;
    9)
      echo "error: hc send refused $target - the terminal is blocked waiting on input (never forced): $out" >&2
      printf 'unknown'
      return 0
      ;;
    *) printf 'send-failed'; return 0 ;;
  esac
  started=$(printf '%s' "$out" | jq -r '.started // empty' 2>/dev/null)
  wait_status=$(printf '%s' "$out" | jq -r '.wait.status // empty' 2>/dev/null)
  if [ "$started" = true ] || [ "$wait_status" = working ]; then
    printf 'empty'
    return 0
  fi
  [ "$settle" = 0 ] || sleep "$settle"
  verdict=$(fm_backend_hc_composer_state "$target" "$expected")
  case "$verdict" in
    pending|pending-unproven)
      fm_composer_submit_retry_core fm_backend_hc_send_key fm_backend_hc_composer_state \
        "$target" "$retries" "$sleep_s" "$expected"
      ;;
    *) printf '%s' "$verdict" ;;
  esac
}

# fm_backend_hc_busy_state: hc's native agent status. `working` is busy; the
# settled words are idle; a terminal with no reported status is unknown.
fm_backend_hc_busy_state() {  # <target> [expected-label]
  local json
  fm_backend_hc_target_ready "$1" "${2:-}" || { printf 'unknown'; return 0; }
  json=$(fm_backend_hc_get "$1") || { printf 'unknown'; return 0; }
  case "$(printf '%s' "$json" | jq -r '.status.state // empty' 2>/dev/null)" in
    working) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_hc_kill: end the program and remove the terminal, then prove it is
# gone. Already absent is a silent success; a terminal still present, a core
# that cannot be read, or a terminal without this home's labels is a refusal.
fm_backend_hc_kill() {  # <target> [unused] [expected-label]
  local target=$1 expected=${3:-'*'} state
  fm_backend_hc_parse_target "$target" || return 1
  state=$(fm_backend_hc_endpoint_state "$target" "$expected")
  case "$state" in
    absent) return 0 ;;
    foreign) echo "error: hc terminal $target does not carry this task's labels; refusing to close it" >&2; return 1 ;;
    unreadable) echo "error: hc terminal $target could not be read, so it was not closed" >&2; return 1 ;;
  esac
  [ "$state" != ready ] || fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" kill --json "$FM_BACKEND_HC_ADDRESS" >/dev/null 2>&1 || true
  fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" rm --json "$FM_BACKEND_HC_ADDRESS" >/dev/null 2>&1 || true
  state=$(fm_backend_hc_endpoint_state "$target")
  case "$state" in
    absent) return 0 ;;
    unreadable) echo "error: hc terminal $target could not be read after its close, so whether it survived is unknown" >&2 ;;
    *) echo "error: hc terminal $target is still present after its close" >&2 ;;
  esac
  return 1
}

# fm_backend_hc_agent_state: recovery-grade state (vocabulary owned by
# bin/fm-backend.sh's fm_backend_agent_state). A structured not_found or a
# finished terminal is `missing`: an hc terminal whose program ended can never
# host the agent again, exactly like a closed tmux window. A live terminal is
# classified from hc's foreground process through the shared classifier.
fm_backend_hc_agent_state() {  # <target>
  local json rc fields state name argv0 args pid class expected=${2:-}
  fm_backend_hc_parse_target "${1:-}" || { printf 'unreadable'; return 0; }
  if json=$(fm_backend_hc_get "$1"); then rc=0; else rc=$?; fi
  if [ "$rc" -eq 3 ]; then printf 'missing'; return 0; fi
  [ "$rc" -eq 0 ] || { printf 'unreadable'; return 0; }
  case "$(fm_backend_hc_snapshot_state "$1" "$expected" "$json")" in
    foreign) printf 'unverified'; return 0 ;;
    unreadable) printf 'unreadable'; return 0 ;;
  esac
  fields=$(printf '%s' "$json" | jq -r '[.state // "", .foreground.name // "", .foreground.argv[0] // "",
    ((.foreground.argv // []) | join(" ")), (.foreground.pid // "" | tostring)] | @tsv' 2>/dev/null) || {
    printf 'unreadable'
    return 0
  }
  IFS=$'\t' read -r state name argv0 args pid <<EOF
$fields
EOF
  case "$state" in
    finished) printf 'missing'; return 0 ;;
    live) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  [ -n "$name$argv0" ] || { printf 'unreadable'; return 0; }
  class=$(fm_agent_process_classify "$name" "$argv0" "$args" "$pid")
  [ "$class" != agent ] || { printf 'alive'; return 0; }
  # A launcher (a wrapper script, or a tool that runs the harness as a child)
  # is what hc names as the foreground; the harness itself is another member
  # of the same foreground process group, which is what tmux reads too. A shell
  # wrapper waiting on the harness is such a launcher, so a shell is only dead
  # once its group holds no harness.
  rc=0
  fm_backend_hc_group_has_agent "$pid" || rc=$?
  [ "$rc" != 0 ] || { printf 'alive'; return 0; }
  [ "$rc" != 2 ] || { printf 'unreadable'; return 0; }
  [ "$class" != shell ] || { printf 'dead'; return 0; }
  printf 'ambiguous'
}

# fm_backend_hc_group_has_agent: whether any other process in <pid>'s process
# group classifies as a harness. Returns 0 for a harness, 1 for a complete
# shell-only group, and 2 for incomplete or unclassified evidence.
fm_backend_hc_group_has_agent() {  # <pid>
  local pid=$1 pgid member mpgid comm args table class uncertain=0 seen=0
  case "$pid" in ''|*[!0123456789]*) return 2 ;; esac
  pgid=$(LC_ALL=C ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || return 2
  [ -n "$pgid" ] || return 2
  table=$(LC_ALL=C ps -A -o pid=,pgid=,comm= 2>/dev/null) || return 2
  [ -n "$table" ] || return 2
  while read -r member mpgid comm; do
    [ "$mpgid" = "$pgid" ] || continue
    [ "$member" != "$pid" ] || { seen=1; continue; }
    if ! args=$(LC_ALL=C ps -o args= -p "$member" 2>/dev/null) || [ -z "$args" ]; then
      uncertain=1
      continue
    fi
    class=$(fm_agent_process_classify "$comm" "${args%% *}" "$args" "$member")
    [ "$class" != agent ] || return 0
    [ "$class" = shell ] || uncertain=1
  done <<EOF
$table
EOF
  [ "$seen" = 1 ] && [ "$uncertain" = 0 ] || return 2
  return 1
}
