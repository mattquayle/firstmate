#!/usr/bin/env bash
# Native local hc secondmate home ownership. Source only.
#
# Spawn holds state/.hc-secondmate-launch.lock in the destination home and
# refuses every lock except free/stale before syncing or wiring that home.
# Before launch it publishes state/.hc-secondmate.json: version, physical home,
# task id, recorded endpoint, terminal shell's kernel pid/start time, permanent
# core id, and the parent home label. The core/label pair also authorizes this
# home's supervisor to address its own endpoint, which its parent labelled.
# fm-lock.sh accepts a harness for that home only when its actual ancestry
# reaches that exact shell incarnation. Neither a parent's environment nor a
# caller-supplied FM_HOME is proof of ownership. The binding is deliberately
# local and independent of foreground titles/status and of hc socket access.
# A stopped terminal's binding remains until a proven safe replacement rewrites
# it; a malformed binding refuses startup. Child task records are never changed.

_FM_HC_SM_LIB_DIR=${BASH_SOURCE[0]%/*}
# shellcheck source=bin/fm-session-lock-lib.sh
. "$_FM_HC_SM_LIB_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$_FM_HC_SM_LIB_DIR/fm-secondmate-parent-lib.sh"

fm_hc_secondmate_pid_stamp() { # <pid>
  case "$1" in ''|0|1|*[!0-9]*) return 1 ;; esac
  local stamp
  stamp=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) || return 1
  [ -n "$stamp" ] || return 1
  printf '%s' "$stamp"
}

fm_hc_secondmate_require_unlocked() { # <home>
  if [ -L "$1/state/.lock" ]; then
    echo "error: secondmate session lock is symlinked; refusing launch" >&2
    return 1
  fi
  fm_session_lock_inspect "$1/state"
  case "$FM_LOCK_INSPECT_STATE" in
    free|stale) return 0 ;;
  esac
  echo "error: secondmate home $1 has a $FM_LOCK_INSPECT_STATE session lock (pid ${FM_LOCK_INSPECT_PID:-unknown}); refusing launch without stealing ownership" >&2
  return 1
}

fm_hc_secondmate_bind() { # <home> <id> <target>; hc adapter already sourced
  local home=$1 id=$2 target=$3 json pid stamp tmp core owner
  home=$(cd "$home" && pwd -P) || return 1
  json=$(fm_backend_hc_get "$target") || return 1
  [ "$(fm_backend_hc_snapshot_state "$target" "fm-$id" "$json")" = ready ] || {
    echo "error: hc terminal ownership is not ready for the secondmate home binding" >&2
    return 1
  }
  pid=$(printf '%s' "$json" | jq -er '.pid | select(type == "number" and . > 1)') || return 1
  stamp=$(fm_hc_secondmate_pid_stamp "$pid") || return 1
  core=$(fm_backend_hc_core_id "${target%%:*}") || return 1
  owner=$(fm_backend_hc_hometag)
  [ ! -L "$home/state/.hc-secondmate.json" ] || return 1
  tmp=$(mktemp "$home/state/.hc-secondmate.XXXXXX") || return 1
  if ! jq -n --arg home "$home" --arg id "$id" --arg target "$target" \
    --arg pid "$pid" --arg stamp "$stamp" --arg core "$core" --arg owner "$owner" \
    '{version:1,home:$home,id:$id,target:$target,pid:$pid,stamp:$stamp,core:$core,owner:$owner}' > "$tmp" \
    || ! mv -f "$tmp" "$home/state/.hc-secondmate.json"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_hc_secondmate_self_identity() { # <home> <target>; hc adapter already sourced
  local home=$1 target=$2 file core owner id
  file="$home/state/.hc-secondmate.json"
  fm_session_lock_inspect "$home/state"
  [ "$FM_LOCK_INSPECT_STATE" = held ] || return 1
  fm_hc_secondmate_lock_owner "$home" "$FM_LOCK_INSPECT_PID" "$target" || return 1
  core=$(jq -er '.core | select(type == "string" and test("^[A-Za-z0-9_-]+$"))' "$file") || return 1
  [ "$(fm_backend_hc_core_id "${target%%:*}")" = "$core" ] || return 1
  owner=$(jq -er '.owner | select(type == "string" and test("^[A-Za-z0-9._-]+$"))' "$file") || return 1
  id=$(cat "$home/.fm-secondmate-home") || return 1
  printf '%s\tfm-%s' "$owner" "$id"
}

fm_hc_secondmate_lock_owner() { # <home> <candidate-harness-pid> [target]
  local home=$1 candidate=$2 target=${3:-} file id pid stamp hops=0
  home=$(cd "$home" && pwd -P) || return 1
  file="$home/state/.hc-secondmate.json"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || return 1
  id=$(cat "$home/.fm-secondmate-home") || return 1
  jq -e --arg home "$home" --arg id "$id" --arg target "$target" '
    type == "object" and .version == 1 and .home == $home and .id == $id
    and (.target | type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9._-]*:t[0-9a-z]+$"))
    and ($target == "" or .target == $target)
    and (.pid | type == "string" and test("^[0-9]+$"))
    and (.stamp | type == "string" and length > 0)' "$file" >/dev/null || return 1
  pid=$(jq -r .pid "$file") || return 1
  stamp=$(fm_hc_secondmate_pid_stamp "$pid") || return 1
  [ "$stamp" = "$(jq -r .stamp "$file")" ] || return 1
  while [ "$hops" -lt 64 ]; do
    [ "$candidate" != "$pid" ] || return 0
    case "$candidate" in ''|0|1|*[!0-9]*) return 1 ;; esac
    candidate=$(fm_ps_ppid "$candidate") || return 1
    hops=$((hops + 1))
  done
  return 1
}

fm_hc_secondmate_control_safe() { # <home> <target>
  local home=$1 target=$2
  fm_session_lock_inspect "$home/state"
  case "$FM_LOCK_INSPECT_STATE" in
    free|stale) return 0 ;;
    held) fm_hc_secondmate_lock_owner "$home" "$FM_LOCK_INSPECT_PID" "$target" && return 0 ;;
  esac
  echo "error: secondmate lock ownership does not match its hc endpoint; refusing lifecycle action" >&2
  return 1
}

# Readiness is the agent AND its home-local startup lock, not the launch line
# having reached a shell. A failure preserves the endpoint and metadata for
# inspection (including a native trust dialog), and never claims healthy spawn.
fm_hc_secondmate_wait_ready() { # <home> <target> <label>
  local home=$1 target=$2 label=$3 i=0 limit=${FM_HC_SECONDMATE_READY_POLLS:-120} state=unknown
  case "$limit" in ''|*[!0-9]*) return 1 ;; esac
  while [ "$i" -lt "$limit" ]; do
    state=$(fm_backend_hc_agent_state "$target" "$label")
    fm_session_lock_inspect "$home/state"
    if [ "$state" = alive ] && [ "$FM_LOCK_INSPECT_STATE" = held ] \
      && fm_hc_secondmate_lock_owner "$home" "$FM_LOCK_INSPECT_PID" "$target"; then
      return 0
    fi
    case "$state" in missing|unverified) break ;; esac
    i=$((i + 1))
    sleep 0.5
  done
  echo "error: native hc secondmate readiness unconfirmed (agent=$state lock=$FM_LOCK_INSPECT_STATE); endpoint $target and home $home preserved; inspect startup or native trust prompts before recovery" >&2
  return 1
}

fm_hc_secondmate_parent_matches() { # <home> <parent>
  local parent recorded
  parent=$(cd "$2" && pwd -P) || return 1
  if fm_secondmate_parent_record_parse "$1/.fm-secondmate-parent" \
    && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
    recorded=$(cd "$FM_SECONDMATE_PARENT_HOME" && pwd -P) || return 1
    [ "$recorded" != "$parent" ] || return 0
  fi
  echo "error: hc secondmate home is not seeded for this local parent; refusing launch" >&2
  return 1
}
