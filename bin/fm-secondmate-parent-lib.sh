#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Parse the durable parent binding written into a seeded secondmate home.
#
# The fm-secondmate-parent.v1 record contains exactly one schema and route.
# A local route contains exactly one absolute parent_home and no parent_host.
# A remote route contains no parent_home; current provisioning includes its SSH
# alias as diagnostic-only parent_host, while legacy-compatible manifests may
# omit that field.
# Native remote records additionally bind control_root, backend=hc, hc_session
# and hc_core_id. The whole native tuple is required, unique and immutable at
# ordinary seed; local PID ownership is still proved by fm-hc-secondmate-lib.sh.
# Unknown fields are reserved for forward-compatible additions.
# Duplicate schema or route fields, a malformed local binding, an unsupported
# route or schema, a NUL-bearing record, and a symlinked record fail closed.
# Writers publish this record before .fm-secondmate-home so that the identity
# marker remains the seed-completion point.

fm_secondmate_parent_record_parse() {
  local file=$1 line schema='' route='' parent_home='' parent_host=''
  local schema_count=0 route_count=0 parent_home_count=0 parent_host_count=0

  local native_count=0 control_root='' backend='' hc_session='' hc_core_id=''
  FM_SECONDMATE_CONTROL_ROOT=
  FM_SECONDMATE_PARENT_BACKEND=
  FM_SECONDMATE_PARENT_HC_SESSION=
  FM_SECONDMATE_PARENT_HC_CORE=
  FM_SECONDMATE_PARENT_ROUTE=
  FM_SECONDMATE_PARENT_HOME=
  FM_SECONDMATE_PARENT_HOST=

  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  # bash's read drops NUL bytes, and different bash generations disagree on the
  # result (3.2 truncates the value at the NUL, 5.x splices the surrounding
  # bytes together), so a NUL-bearing parent_home can resolve to a home the
  # record's bytes never name contiguously. Reject the whole record as corrupt
  # before any field parsing instead of letting the interpreter pick a home.
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*)
        schema_count=$((schema_count + 1))
        schema=${line#schema=}
        ;;
      route=*)
        route_count=$((route_count + 1))
        route=${line#route=}
        ;;
      parent_home=*)
        parent_home_count=$((parent_home_count + 1))
        parent_home=${line#parent_home=}
        ;;
      control_root=*) [ -z "$control_root" ] || return 1; control_root=${line#*=}; native_count=$((native_count + 1)) ;;
      backend=*) [ -z "$backend" ] || return 1; backend=${line#*=}; native_count=$((native_count + 1)) ;;
      hc_session=*) [ -z "$hc_session" ] || return 1; hc_session=${line#*=}; native_count=$((native_count + 1)) ;;
      hc_core_id=*) [ -z "$hc_core_id" ] || return 1; hc_core_id=${line#*=}; native_count=$((native_count + 1)) ;;
      parent_host=*)
        parent_host_count=$((parent_host_count + 1))
        parent_host=${line#parent_host=}
        ;;
    esac
  done < "$file"

  [ "$schema_count" -eq 1 ] || return 1
  [ "$route_count" -eq 1 ] || return 1
  [ "$schema" = fm-secondmate-parent.v1 ] || return 1
  case "$route" in
    local)
      [ "$parent_home_count" -eq 1 ] || return 1
      [ "$parent_host_count" -eq 0 ] || return 1
      case "$parent_home" in /*) ;; *) return 1 ;; esac
      FM_SECONDMATE_PARENT_HOME=$parent_home
      ;;
    remote)
      [ "$parent_home_count" -eq 0 ] || return 1
      ;;
    *) return 1 ;;
  esac

  if [ "$native_count" != 0 ]; then
    [ "$native_count" = 4 ] && [ "$route" = remote ] && [ "$backend" = hc ] || return 1
    case "$control_root" in /*) ;; *) return 1 ;; esac
    case "$control_root" in *$'\t'*|*$'\r'*|*'//'*) return 1 ;; esac
    case "/$control_root/" in */../*|*/./*) return 1 ;; esac
    [[ "$hc_session" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || return 1
    [[ "$hc_core_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    FM_SECONDMATE_CONTROL_ROOT=$control_root
    FM_SECONDMATE_PARENT_BACKEND=$backend
    FM_SECONDMATE_PARENT_HC_SESSION=$hc_session
    FM_SECONDMATE_PARENT_HC_CORE=$hc_core_id
  fi
  FM_SECONDMATE_PARENT_ROUTE=$route
  FM_SECONDMATE_PARENT_HOST=$parent_host
}
