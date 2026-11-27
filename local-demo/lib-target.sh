# shellcheck shell=bash
# lib-target.sh — shared by target.sh and the three ui.sh scripts (local-demo/,
# eks-infrastructure/scripts/, eks-infrastructure-managed/scripts/).
#
# Each ui.sh records the PIDs of the background processes it starts (port-forwards,
# kubectl proxy, dashboard-server.py), so `target.sh stop <target>` stops exactly
# those, and never another demo copy that happens to use the same ports.
#
#   target_track_reset <name>   start a new PID list for this target
#   target_track <pid>          add a PID to it
TARGET_STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/com323-demo"

target_pidfile() { echo "${TARGET_STATE_DIR}/$1.pids"; }

target_track_reset() {
  mkdir -p "${TARGET_STATE_DIR}"
  TARGET_PIDFILE="$(target_pidfile "$1")"
  : > "${TARGET_PIDFILE}"
}

target_track() {
  if [[ -n "${TARGET_PIDFILE:-}" ]]; then echo "$1" >> "${TARGET_PIDFILE}"; fi
  return 0
}
