#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id>
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# legacy read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them. Native hc routes use one read-only check and never automatic repair.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id>
  local bin_dir=$1 id=$2 out rc backend reg session core
  local -a native_args
  native_args=()
  # The registry, not ambient backend/session variables, owns remote selection.
  # Native readiness never invokes automatic repair or core lifecycle commands.
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$bin_dir/fm-secondmate-registry-lib.sh"
  reg="${FM_DATA_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-${bin_dir%/bin}}}/data}/secondmates.md"
  backend=$(secondmate_registry_field "$reg" "$id" backend) || { FM_REMOTE_READINESS_OUT="invalid or ambiguous remote registry entry for $id"; return 1; }
  if [ "$backend" = hc ]; then
    session=$(secondmate_registry_field "$reg" "$id" hc_session) || return 1
    core=$(secondmate_registry_field "$reg" "$id" hc_core_id) || return 1
    native_args=(--backend hc --hc-session "$session" --hc-core-id "$core")
  fi

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "${native_args[@]}" < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255
  [ "$backend" != hc ] || return "$rc"

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh --fix < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "${native_args[@]}" < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}
