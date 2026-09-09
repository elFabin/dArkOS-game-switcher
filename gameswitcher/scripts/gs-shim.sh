#!/bin/bash
#############################################################################
# gs-shim.sh - installed over /usr/local/bin/retroarch and .../retroarch32.
#
# EmulationStation launches a game with
#   sh -c "sudo perfmax %GOVERNOR% %ROM%; nice -n -19 /usr/local/bin/retroarch \
#          -L <core> %ROM%; sudo perfnorm"
# and blocks until that command returns.  By looping here we can quit one
# game, show the switcher, and start another without ES ever regaining the
# screen - so switching costs a game launch, not an ES restart.
#
# The stock dArkOS wrapper is preserved at /opt/gameswitcher/orig/<name> and
# still invoked under its original basename, because it branches on
# `basename "$0"` to serve both retroarch and retroarch32.
#############################################################################

# shellcheck disable=SC1090
. "${GS_COMMON:-/usr/local/bin/gs-common.sh}"

emulator="$(basename "$0")"
orig="${GS_OPT}/orig/${emulator}"

# ---------------------------------------------------------------------------
# Pull the core and ROM back out of the argv ES handed us.
# ---------------------------------------------------------------------------
gs_parse_args() {
  GS_CORE=""
  GS_ROM=""
  local expect_value="" arg
  for arg in "$@"; do
    if [ -n "${expect_value}" ]; then
      [ "${expect_value}" = "core" ] && GS_CORE="${arg}"
      expect_value=""
      continue
    fi
    case "${arg}" in
      -L|--libretro) expect_value="core" ;;
      -c|--config|--appendconfig|--subsystem|--size|--nick) expect_value="skip" ;;
      -*) ;;
      *) GS_ROM="${arg}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Run the switcher UI.  The SDL2 carousel is preferred; the dialog menu is the
# fallback wherever it could not be compiled.
# ---------------------------------------------------------------------------
gs_run_ui() {
  rm -f "${GS_CHOICE}" 2>/dev/null
  if [ -x "${GS_OPT}/gameswitcher" ]; then
    SDL_VIDEO_EGL_DRIVER="libEGL.so" \
    SDL_GAMECONTROLLERCONFIG_FILE="/opt/inttools/gamecontrollerdb.txt" \
      "${GS_OPT}/gameswitcher"
    return $?
  fi
  "${GS_BIN}/gs-menu.sh"
}

# perfmax draws the launch splash for a ROM and pins the governors.  ES only
# calls it once, for the first game, so re-run it for each game we switch to.
# The governor ES chose is not passed down to us, so carry forward whatever is
# in effect rather than guessing a new one.
gs_splash() {
  local rom="$1" governor
  [ "${GS_SHOW_SPLASH}" = "1" ] || return 0
  [ -x /usr/local/bin/perfmax ] || return 0
  governor="$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)"
  [ -n "${governor}" ] || return 0
  sudo /usr/local/bin/perfmax "${governor}" "${rom}" >/dev/null 2>&1 || true
}

# X on the carousel means "start this one over": move the auto savestate aside
# rather than deleting it, so a mis-press is recoverable.  scripts/get_last_played.sh
# offers the same escape hatch behind a held R1 at boot.
gs_clear_autostate() {
  local rom="$1" base state
  [ -n "${rom}" ] || return 0
  base="${rom%.*}"
  for state in "${base}.state.auto" "${rom}.state.auto"; do
    [ -f "${state}" ] || continue
    mv -f "${state}" "${state}.bak" 2>/dev/null || rm -f "${state}" 2>/dev/null
  done
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

if [ ! -x "${orig}" ]; then
  # A half-finished install must never cost the user their game.  Fall through
  # to the real binary the way the stock wrapper's final line does.
  gs_log "original ${emulator} wrapper missing, launching directly"
  exec "/opt/retroarch/bin/${emulator}" -c "${GS_HOME}/.config/${emulator}/retroarch.cfg" "$@"
fi

trap 'gs_session_clear' EXIT

args=("$@")
rc=0

while true; do
  gs_parse_args "${args[@]}"
  if [ -n "${GS_ROM}" ]; then
    gs_recents_add "${emulator}" "${GS_CORE}" "${GS_ROM}"
    gs_session_write "${emulator}" "${GS_CORE}" "${GS_ROM}" "$(gs_key "${GS_ROM}")"
  fi

  rm -f "${GS_SWITCH}" 2>/dev/null
  "${orig}" "${args[@]}"
  rc=$?
  gs_session_clear

  # No switch was asked for: the player quit normally, hand the screen back
  # to EmulationStation exactly as the stock wrapper would.
  [ -e "${GS_SWITCH}" ] || break
  rm -f "${GS_SWITCH}" 2>/dev/null

  # Stay in the switcher until the player picks a game or leaves.
  relaunch=""
  while [ -z "${relaunch}" ]; do
    gs_run_ui
    ui_rc=$?
    case "${ui_rc}" in
      0)
        gs_choice_read || break
        case "${GS_C_ACTION}" in
          remove)
            gs_recents_remove "${GS_C_KEY}"
            ;;
          launch|restart)
            [ -n "${GS_C_ROM}" ] || continue
            [ "${GS_C_ACTION}" = "restart" ] && gs_clear_autostate "${GS_C_ROM}"
            relaunch="yes"
            ;;
          *) break ;;
        esac
        ;;
      11)
        # Sleep, then come back to the carousel on wake.
        sudo systemctl suspend >/dev/null 2>&1
        ;;
      *)
        break
        ;;
    esac
  done

  [ -n "${relaunch}" ] || break

  # A game from another system may want a different RetroArch build; switching
  # emulator here would need a different orig wrapper, so re-exec ourselves
  # under the right name instead.
  if [ -n "${GS_C_EMULATOR}" ] && [ "${GS_C_EMULATOR}" != "${emulator}" ] \
     && [ -x "${GS_BIN}/${GS_C_EMULATOR}" ]; then
    gs_splash "${GS_C_ROM}"
    exec "${GS_BIN}/${GS_C_EMULATOR}" -L "${GS_C_CORE}" "${GS_C_ROM}"
  fi

  gs_splash "${GS_C_ROM}"
  args=(-L "${GS_C_CORE}" "${GS_C_ROM}")
done

exit "${rc}"
