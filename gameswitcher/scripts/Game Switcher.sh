#!/bin/bash
#############################################################################
# Game Switcher.sh - the Options menu entry (/opt/system/Game Switcher.sh).
#
# Opens the carousel straight from EmulationStation, so recent games are
# reachable after a reboot and not only mid-session.  Picking a game hands off
# to /usr/local/bin/<emulator>, which is the shim - from there the normal
# suspend/switch loop takes over.
#############################################################################

# shellcheck disable=SC1090
. "${GS_COMMON:-/usr/local/bin/gs-common.sh}"

# Reachable two ways now: the Options menu entry (always safe -- ES's menu
# isn't reachable while a game or standalone emulator has the screen anyway)
# and a system-wide Fn tap via gs-hotkeyd-idle.service, which fires blindly
# on every clean tap regardless of what's currently running.  Bail before
# touching the display if a RetroArch session is already active (the
# in-game watcher owns that case -- see gs-suspend.sh) or a standalone
# emulator has the screen (gs_foreign_emulator_running).
if gs_session_read && kill -0 "${GS_S_PID}" 2>/dev/null; then
  exit 0
fi
gs_foreign_emulator_running && exit 0

gs_init_dirs
gs_recents_seed

# Unlike the mid-game invocation (gs-shim.sh replaces retroarch, so ES is
# structurally guaranteed to be blocked in its own system() call), ES is
# genuinely alive and rendering its own menu when this script is reached
# idle -- nothing stops it from continuing to draw while the carousel also
# tries to.  Same self-heal/freeze/trap/watchdog sequence gs-shim.sh uses.
gs_es_resume
gs_es_freeze
trap 'gs_es_resume' EXIT
gs_es_watchdog_start "$$"

run_ui() {
  rm -f "${GS_CHOICE}" 2>/dev/null
  if [ -x "${GS_OPT}/gameswitcher" ]; then
    SDL_VIDEO_EGL_DRIVER="libEGL.so" \
    SDL_GAMECONTROLLERCONFIG_FILE="/opt/inttools/gamecontrollerdb.txt" \
      "${GS_OPT}/gameswitcher"
    local rc=$?
    if [ "${rc}" -ne "${GS_UI_FAILED_RC:-12}" ]; then
      return "${rc}"
    fi
    gs_log "carousel failed to start, falling back to the text menu"
  fi
  "${GS_BIN}/gs-menu.sh"
}

while true; do
  run_ui
  rc=$?

  case "${rc}" in
    11)
      sudo systemctl suspend >/dev/null 2>&1
      continue
      ;;
    0) ;;
    *) exit 0 ;;
  esac

  gs_choice_read || exit 0

  case "${GS_C_ACTION}" in
    remove)
      gs_recents_remove "${GS_C_KEY}"
      continue
      ;;
    restart)
      base="${GS_C_ROM%.*}"
      [ -f "${base}.state.auto" ] && mv -f "${base}.state.auto" "${base}.state.auto.bak" 2>/dev/null
      ;;
    launch) ;;
    *) exit 0 ;;
  esac

  [ -n "${GS_C_ROM}" ] || exit 0
  emulator="${GS_C_EMULATOR:-retroarch}"
  [ -x "${GS_BIN}/${emulator}" ] || exit 0

  governor="$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)"
  [ -n "${governor}" ] && [ -x /usr/local/bin/perfmax ] && \
    sudo /usr/local/bin/perfmax "${governor}" "${GS_C_ROM}" >/dev/null 2>&1

  # GS_ES_FROZEN=1 tells the shim we already froze ES ourselves above, so it
  # skips its own self-heal/freeze -- otherwise that resume-then-refreeze
  # blip lands right as the game is trying to take the screen.  See gs-shim.sh.
  GS_ES_FROZEN=1 SDL_VIDEO_EGL_DRIVER="libEGL.so" nice -n -19 \
    "${GS_BIN}/${emulator}" -L "${GS_C_CORE}" "${GS_C_ROM}"

  [ -x /usr/local/bin/perfnorm ] && sudo /usr/local/bin/perfnorm >/dev/null 2>&1

  # The shim already ran its own switch loop; coming back here means the
  # player left it, so return to EmulationStation.
  exit 0
done
