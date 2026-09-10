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
#
# Also runs the Fn-tap watcher (gs-hotkeyd.py) for the life of the loop when
# GS_TRIGGER includes "fn", and freezes EmulationStation for the same span --
# see gs-common.sh for both.
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
# fallback wherever it could not be compiled, and also the fallback for a
# single failed run (a lost DRM-master race, say) rather than exit codes 10
# and 11, so a failed carousel degrades to the text menu instead of silently
# dumping the player back to EmulationStation.
# ---------------------------------------------------------------------------
gs_run_ui() {
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

# ---------------------------------------------------------------------------
# The Fn-tap watcher (GS_TRIGGER=fn|both).  Started once for the whole switch
# session and stopped on every exit path, the same bracket ppsspp/ppsspp.sh
# puts around watchpsp.sh.  It fires gs-suspend.sh itself; the shim only has
# to keep it alive for exactly as long as a game might be running.
# ---------------------------------------------------------------------------
GS_HOTKEYD_PID=""

gs_hotkeyd_start() {
  case "${GS_TRIGGER}" in
    fn|both) ;;
    *) return 0 ;;
  esac
  command -v python3 >/dev/null 2>&1 || return 0
  [ -x "${GS_BIN}/gs-hotkeyd.py" ] || return 0
  # Deliberately not `disown`ed: gs_hotkeyd_stop needs `wait` to actually
  # reap this PID on the way out, and `disown` (tested directly) makes bash
  # report a successful wait without ever calling waitpid(), leaving a
  # zombie behind instead.  We're never in an interactive shell here (ES
  # runs us via `sh -c "..."`), so there is no job-control status line to
  # suppress in the first place.
  GS_HOTKEY_CODE="${GS_HOTKEY_CODE}" GS_HOTKEY_DEVICE="${GS_HOTKEY_DEVICE}" \
    GS_HOTKEY_ACTION="${GS_BIN}/gs-suspend.sh" \
    "${GS_BIN}/gs-hotkeyd.py" &
  GS_HOTKEYD_PID=$!
}

gs_hotkeyd_stop() {
  [ -n "${GS_HOTKEYD_PID}" ] || return 0
  kill "${GS_HOTKEYD_PID}" 2>/dev/null
  wait "${GS_HOTKEYD_PID}" 2>/dev/null
  GS_HOTKEYD_PID=""
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

# Self-heal first: a prior run that was killed outright (SIGKILL bypasses any
# trap) may have left EmulationStation frozen.  Always start from a known
# state before possibly freezing it again ourselves.
gs_es_resume

trap 'gs_session_clear; gs_es_resume; gs_hotkeyd_stop' EXIT

gs_es_freeze
gs_es_watchdog_start "$$"
gs_hotkeyd_start

args=("$@")
rc=0

while true; do
  gs_parse_args "${args[@]}"
  if [ -n "${GS_ROM}" ]; then
    gs_recents_add "${emulator}" "${GS_CORE}" "${GS_ROM}"
  fi

  rm -f "${GS_SWITCH}" 2>/dev/null
  # Backgrounded (not a plain foreground call) so we can capture its own PID
  # and track it precisely -- gs-suspend.sh needs to signal exactly this
  # process, never anything matched by name.  "orig" is our copy of the
  # stock wrapper, itself a script with the same basename ("retroarch" or
  # "retroarch32") as this shim: the kernel sets a directly-exec'd script's
  # comm to its own basename (confirmed directly, not assumed), so this
  # process and the real RetroArch binary it eventually execs into are
  # indistinguishable by name -- a name-based pkill/pgrep can just as easily
  # match this shim's own PID as the game's.
  "${orig}" "${args[@]}" &
  ra_pid=$!
  [ -n "${GS_ROM}" ] && \
    gs_session_write "${emulator}" "${GS_CORE}" "${GS_ROM}" "$(gs_key "${GS_ROM}")" "${ra_pid}"
  wait "${ra_pid}"
  rc=$?
  gs_session_clear

  # No switch was asked for: the player quit normally, hand the screen back
  # to EmulationStation exactly as the stock wrapper would.
  [ -e "${GS_SWITCH}" ] || break
  rm -f "${GS_SWITCH}" 2>/dev/null

  # Let a just-exited RetroArch's GPU/DRM teardown actually settle before we
  # contend for the display -- see gs_wait_for_teardown's comment.
  gs_wait_for_teardown

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
  # under the right name instead.  A successful exec replaces this process
  # outright, so our EXIT trap never runs for it: stop what only we know
  # about first.  ES itself needs no such care -- the freshly exec'd shim
  # (still gs-shim.sh, just under the other emulator's name) unconditionally
  # self-heals with its own gs_es_resume before it re-freezes.
  if [ -n "${GS_C_EMULATOR}" ] && [ "${GS_C_EMULATOR}" != "${emulator}" ] \
     && [ -x "${GS_BIN}/${GS_C_EMULATOR}" ]; then
    gs_hotkeyd_stop
    gs_splash "${GS_C_ROM}"
    exec "${GS_BIN}/${GS_C_EMULATOR}" -L "${GS_C_CORE}" "${GS_C_ROM}"
  fi

  gs_splash "${GS_C_ROM}"
  args=(-L "${GS_C_CORE}" "${GS_C_ROM}")
done

exit "${rc}"
