#!/bin/bash
#############################################################################
# Game Switcher.sh - the Options menu entry (/opt/system/Game Switcher.sh).
#
# Opens the carousel straight from EmulationStation, so recent games are
# reachable after a reboot and not only mid-session.  Picking a game hands off
# to /usr/local/bin/<emulator>, which is the shim - from there the normal
# suspend/switch loop takes over.
#
# Only reachable this way -- ES's own menu can't be on screen while a game
# or standalone emulator already has the display, and ES itself deinits its
# renderer before running any Options-menu script (GuiTools::launchTool in
# EmulationStation-fcamod), so nothing here needs to guard against that or
# freeze ES itself.
#############################################################################

# shellcheck disable=SC1090
. "${GS_COMMON:-/usr/local/bin/gs-common.sh}"

gs_init_dirs
gs_recents_seed

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

  SDL_VIDEO_EGL_DRIVER="libEGL.so" nice -n -19 \
    "${GS_BIN}/${emulator}" -L "${GS_C_CORE}" "${GS_C_ROM}"

  [ -x /usr/local/bin/perfnorm ] && sudo /usr/local/bin/perfnorm >/dev/null 2>&1

  # The shim already ran its own switch loop; coming back here means the
  # player left it, so return to EmulationStation.
  exit 0
done
