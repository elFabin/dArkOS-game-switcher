#!/bin/bash
#############################################################################
# shim_case.sh - drive gs-shim.sh through the switch loop with a stubbed
# RetroArch and a stubbed carousel, so the state machine can be checked
# without a device.
#############################################################################

set -u

ROOT="$1"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    printf '    ok   %s\n' "$1"
  else
    printf '    FAIL %s: expected [%s], got [%s]\n' "$1" "$3" "$2"
    FAIL=1
  fi
}

export GS_HOME="${WORK}/home"
export GS_STATE="${WORK}/state"
export GS_OPT="${WORK}/opt"
export GS_BIN="${WORK}/bin"
export GS_RUN="${WORK}/run"
export GS_COMMON="${ROOT}/scripts/gs-common.sh"
export GS_SHOW_SPLASH=0
mkdir -p "${GS_HOME}" "${GS_STATE}" "${GS_OPT}/orig" "${GS_BIN}" "${GS_RUN}"

# A RetroArch that logs how it was invoked and, when the scenario says so,
# leaves the switch marker behind the way gs-suspend.sh would.  "hang" never
# returns on its own (ignoring the QUIT sent over the network) -- used to
# exercise gs-suspend.sh's own force-kill escalation for real, rather than
# the stubbed gs-suspend.sh the other scenarios use.
cat > "${GS_OPT}/orig/retroarch" <<'STUB'
#!/bin/bash
echo "$*" >> "${WORK}/launches.log"
n=$(cat "${WORK}/ra.turn" 2>/dev/null || echo 1)
echo $(( n + 1 )) > "${WORK}/ra.turn"
action=$(sed -n "${n}p" "${WORK}/ra.plan")
if [ "${action}" = "hang" ]; then
  sleep 100
fi
[ "${action}" = "switch" ] && : > "${GS_RUN}/gs_switch"
exit 0
STUB
chmod +x "${GS_OPT}/orig/retroarch"

# A carousel that replays scripted answers.
cat > "${GS_OPT}/gameswitcher" <<'STUB'
#!/bin/bash
n=$(cat "${WORK}/ui.turn" 2>/dev/null || echo 1)
echo $(( n + 1 )) > "${WORK}/ui.turn"
line=$(sed -n "${n}p" "${WORK}/ui.plan")
IFS='|' read -r action rom core emulator <<< "${line}"
case "${action}" in
  back)  exit 10 ;;
  sleep) exit 11 ;;
esac
{
  echo "action=${action}"
  echo "key=$(printf '%s' "${rom}" | sha1sum | cut -c1-16)"
  echo "emulator=${emulator}"
  echo "core=${core}"
  echo "rom=${rom}"
} > "${GS_RUN}/gs_choice"
exit 0
STUB
chmod +x "${GS_OPT}/gameswitcher"
export WORK

cp "${ROOT}/scripts/gs-shim.sh" "${GS_BIN}/retroarch"
chmod +x "${GS_BIN}/retroarch"

reset_case() {
  rm -f "${WORK}/launches.log" "${WORK}/ra.turn" "${WORK}/ui.turn" \
        "${GS_RUN}"/gs_* "${GS_STATE}/recents.tsv"
  : > "${WORK}/launches.log"
}

# --- 1. A normal quit must behave exactly like the stock wrapper -----------
reset_case
printf 'end\n' > "${WORK}/ra.plan"
: > "${WORK}/ui.plan"
"${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc
check "normal quit runs the game once" "$(wc -l < "${WORK}/launches.log")" "1"
check "normal quit does not open the UI" "$(cat "${WORK}/ui.turn" 2>/dev/null || echo 1)" "1"
check "the game was recorded" "$(head -1 "${GS_STATE}/recents.tsv" | cut -f7)" "/roms/snes/One.sfc"

# --- 2. Suspend, pick another game, then quit ------------------------------
reset_case
printf 'switch\nend\n' > "${WORK}/ra.plan"
printf 'launch|/roms/gba/Two.gba|/cores/mgba.so|retroarch\n' > "${WORK}/ui.plan"
"${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc
check "two games were launched" "$(wc -l < "${WORK}/launches.log")" "2"
check "the second launch used the picked game" \
      "$(sed -n 2p "${WORK}/launches.log")" "-L /cores/mgba.so /roms/gba/Two.gba"
check "both games are in recents" "$(wc -l < "${GS_STATE}/recents.tsv")" "2"
check "the game just played is first" \
      "$(head -1 "${GS_STATE}/recents.tsv" | cut -f7)" "/roms/gba/Two.gba"
check "the switch marker was consumed" \
      "$([ -e "${GS_RUN}/gs_switch" ] && echo present || echo gone)" "gone"
check "the session marker was cleared" \
      "$([ -e "${GS_RUN}/gs_session" ] && echo present || echo gone)" "gone"

# --- 3. Remove keeps the switcher open, then Back returns to ES ------------
reset_case
printf 'switch\n' > "${WORK}/ra.plan"
printf 'remove|/roms/snes/One.sfc|/cores/snes9x.so|retroarch\nback\n' > "${WORK}/ui.plan"
"${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc
check "removing does not launch anything else" "$(wc -l < "${WORK}/launches.log")" "1"
check "the carousel was shown twice" "$(cat "${WORK}/ui.turn")" "3"
check "the removed game is gone" \
      "$(grep -c 'One.sfc' "${GS_STATE}/recents.tsv" 2>/dev/null || true)" "0"

# --- 4. Start over sets the auto savestate aside --------------------------
reset_case
mkdir -p "${WORK}/roms"
: > "${WORK}/roms/Three.sfc"
: > "${WORK}/roms/Three.state.auto"
printf 'switch\nend\n' > "${WORK}/ra.plan"
printf 'restart|%s/roms/Three.sfc|/cores/snes9x.so|retroarch\n' "${WORK}" > "${WORK}/ui.plan"
"${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc
check "the auto savestate was moved aside" \
      "$([ -e "${WORK}/roms/Three.state.auto" ] && echo present || echo gone)" "gone"
check "and kept as a backup" \
      "$([ -e "${WORK}/roms/Three.state.auto.bak" ] && echo present || echo gone)" "present"
check "the restarted game was launched" \
      "$(sed -n 2p "${WORK}/launches.log")" "-L /cores/snes9x.so ${WORK}/roms/Three.sfc"

# --- 5. pause.sh defers to stock with the default trigger (fn) -------------
cp "${ROOT}/scripts/pause.sh.gs" "${GS_BIN}/pause.sh"
cat > "${GS_BIN}/pause.sh.gs-orig" <<'STUB'
#!/bin/bash
echo "stock" > "${WORK}/pause.result"
STUB
cat > "${GS_BIN}/gs-suspend.sh" <<'STUB'
#!/bin/bash
echo "switcher" > "${WORK}/pause.result"
STUB
chmod +x "${GS_BIN}/pause.sh" "${GS_BIN}/pause.sh.gs-orig" "${GS_BIN}/gs-suspend.sh"

# pgrep must see a live 'retroarch' for the hook to fire; fake one on PATH.
STUBBIN="${WORK}/stubbin"
mkdir -p "${STUBBIN}"
printf '#!/bin/bash\n[ "$*" = "-x retroarch" ] && exit 0\nexit 1\n' > "${STUBBIN}/pgrep"
chmod +x "${STUBBIN}/pgrep"
: > "${GS_RUN}/gs_session"

# GS_TRIGGER defaults to "fn": a power press must stay plain suspend even
# with a game running and a live session marker, matching "power should go
# back to plain suspend" from the bug report.
GS_TRIGGER=fn PATH="${STUBBIN}:${PATH}" "${GS_BIN}/pause.sh"
check "fn trigger -> power press stays stock, even mid-game" \
      "$(cat "${WORK}/pause.result")" "stock"

# --- 6. pause.sh intercepts once the power trigger is turned on ------------
rm -f "${GS_RUN}/gs_session"
GS_TRIGGER=power "${GS_BIN}/pause.sh"
check "power trigger, no game running -> stock pause.sh" \
      "$(cat "${WORK}/pause.result")" "stock"

: > "${GS_RUN}/gs_session"
GS_TRIGGER=power PATH="${STUBBIN}:${PATH}" "${GS_BIN}/pause.sh"
check "power trigger, game running -> switcher" \
      "$(cat "${WORK}/pause.result")" "switcher"

GS_TRIGGER=both PATH="${STUBBIN}:${PATH}" "${GS_BIN}/pause.sh"
check "both trigger, game running -> switcher too" \
      "$(cat "${WORK}/pause.result")" "switcher"

# --- 7. the Fn watcher only starts for fn|both, and is always gone after ---
cat > "${GS_BIN}/gs-hotkeyd.py" <<'STUB'
#!/bin/bash
echo $$ > "${WORK}/hotkeyd.pid"
: > "${WORK}/hotkeyd.started"
trap 'exit 0' TERM
while true; do sleep 0.05; done
STUB
chmod +x "${GS_BIN}/gs-hotkeyd.py"

reset_case
rm -f "${WORK}/hotkeyd.started" "${WORK}/hotkeyd.pid"
printf 'end\n' > "${WORK}/ra.plan"
: > "${WORK}/ui.plan"
GS_TRIGGER=fn "${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc
check "fn trigger starts the Fn watcher" \
      "$([ -e "${WORK}/hotkeyd.started" ] && echo yes || echo no)" "yes"
check "the watcher is gone once the shim exits" \
      "$(kill -0 "$(cat "${WORK}/hotkeyd.pid")" 2>/dev/null && echo alive || echo gone)" "gone"

reset_case
rm -f "${WORK}/hotkeyd.started" "${WORK}/hotkeyd.pid"
GS_TRIGGER=power "${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc
check "power-only trigger never starts the Fn watcher" \
      "$([ -e "${WORK}/hotkeyd.started" ] && echo yes || echo no)" "no"

# --- 8. a carousel that fails to start falls back to the text menu ---------
cat > "${GS_BIN}/gs-menu.sh" <<'STUB'
#!/bin/bash
n=$(cat "${WORK}/ui.turn" 2>/dev/null || echo 1)
echo $(( n + 1 )) > "${WORK}/ui.turn"
echo "menu" >> "${WORK}/ui-source.log"
line=$(sed -n "${n}p" "${WORK}/ui.plan")
IFS='|' read -r action rom core emulator <<< "${line}"
case "${action}" in
  back)  exit 10 ;;
  sleep) exit 11 ;;
esac
{
  echo "action=${action}"
  echo "key=$(printf '%s' "${rom}" | sha1sum | cut -c1-16)"
  echo "emulator=${emulator}"
  echo "core=${core}"
  echo "rom=${rom}"
} > "${GS_RUN}/gs_choice"
exit 0
STUB
chmod +x "${GS_BIN}/gs-menu.sh"
# The scripted carousel stub already exits 12 for the action "fail".
sed -i 's/^  back)  exit 10 ;;$/  back)  exit 10 ;;\n  fail)  exit 12 ;;/' "${GS_OPT}/gameswitcher"

reset_case
rm -f "${WORK}/ui-source.log"
printf 'switch\nend\n' > "${WORK}/ra.plan"
printf 'fail\nlaunch|/roms/gba/Two.gba|/cores/mgba.so|retroarch\n' > "${WORK}/ui.plan"
"${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc
check "a failed carousel does not leave the player stranded in ES" \
      "$(wc -l < "${WORK}/launches.log")" "2"
check "the text menu served the fallback" \
      "$(cat "${WORK}/ui-source.log" 2>/dev/null)" "menu"

# --- 9. gs-shim.sh always stops and resumes the real EmulationStation binary
# (freezing ES is unconditional now, no setting to turn it on).  gs_es_pid
# resolves the real binary's PID itself rather than trusting
# systemd's MainPID for the service (which is actually the passive wrapper
# script, emulationstation.sh -- see the comment above gs_es_pid), then
# gs_es_freeze/resume signal that PID directly via `sudo kill`.  So this
# stubs three things on PATH: `systemctl` (answers the MainPID lookup with a
# fixed wrapper PID), `pgrep` (answers the child lookup with a fixed "real
# ES" PID, falling through to the real pgrep for any other call so
# gs_ra_running's own `pgrep -x retroarch` keeps working), and `sudo` (logs
# whatever it's asked to run, same as before -- confirmed separately that
# `sudo` itself resolves via the calling shell's ordinary PATH lookup, not
# its own internal secure_path, so stubbing it here is reliable).
SUDOBIN="${WORK}/sudobin"
mkdir -p "${SUDOBIN}"
cat > "${SUDOBIN}/sudo" <<'STUB'
#!/bin/bash
echo "$*" >> "${WORK}/sudo.log"
exit 0
STUB
chmod +x "${SUDOBIN}/sudo"

cat > "${SUDOBIN}/systemctl" <<'STUB'
#!/bin/bash
if [ "$1" = "show" ] && [ "$2" = "-p" ] && [ "$3" = "MainPID" ] && [ "$4" = "--value" ] \
   && [ "$5" = "emulationstation.service" ]; then
  echo 5000
  exit 0
fi
exit 1
STUB
chmod +x "${SUDOBIN}/systemctl"

cat > "${SUDOBIN}/pgrep" <<'STUB'
#!/bin/bash
if [ "$1" = "-P" ] && [ "$2" = "5000" ] && [ "$3" = "-f" ] && [ "$4" = "emulationstation" ]; then
  echo 5001
  exit 0
fi
exec /usr/bin/pgrep "$@"
STUB
chmod +x "${SUDOBIN}/pgrep"

reset_case
rm -f "${WORK}/sudo.log"
printf 'end\n' > "${WORK}/ra.plan"
: > "${WORK}/ui.plan"
PATH="${SUDOBIN}:${PATH}" "${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc
check "freeze stops the real EmulationStation binary, not its wrapper" \
      "$(grep -c -- 'kill -STOP 5001' "${WORK}/sudo.log")" "1"
check "freeze resumes the real EmulationStation binary on a normal exit" \
      "$(grep -c -- 'kill -CONT 5001' "${WORK}/sudo.log")" "2"

# A SIGKILLed shim skips its own EXIT trap entirely (SIGKILL can't be
# caught), so the *next* shim invocation is what has to notice and resume
# EmulationStation -- the "self-heal first" line at the top of gs-shim.sh.
reset_case
rm -f "${WORK}/sudo.log"
cat > "${GS_OPT}/orig/retroarch" <<'STUB'
#!/bin/bash
echo "$*" >> "${WORK}/launches.log"
kill -KILL "$PPID"
STUB
chmod +x "${GS_OPT}/orig/retroarch"
PATH="${SUDOBIN}:${PATH}" "${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/Killed.sfc >/dev/null 2>&1
check "a SIGKILLed shim still froze the real ES binary once" \
      "$(grep -c -- 'kill -STOP 5001' "${WORK}/sudo.log")" "1"

# Restore the well-behaved stub before the next, ordinary invocation.
cat > "${GS_OPT}/orig/retroarch" <<'STUB'
#!/bin/bash
echo "$*" >> "${WORK}/launches.log"
n=$(cat "${WORK}/ra.turn" 2>/dev/null || echo 1)
echo $(( n + 1 )) > "${WORK}/ra.turn"
action=$(sed -n "${n}p" "${WORK}/ra.plan")
[ "${action}" = "switch" ] && : > "${GS_RUN}/gs_switch"
exit 0
STUB
chmod +x "${GS_OPT}/orig/retroarch"
printf 'end\n' > "${WORK}/ra.plan"
rm -f "${WORK}/sudo.log"
PATH="${SUDOBIN}:${PATH}" "${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/Two.sfc >/dev/null 2>&1
check "the next shim invocation self-heals the stale freeze before anything else" \
      "$(head -1 "${WORK}/sudo.log")" "kill -CONT 5001"

# --- 10. gs-suspend.sh's own escalation must never kill gs-shim.sh itself --
# gs-shim.sh is installed as a file literally named "retroarch" and directly
# exec'd by path, so the kernel gives its process the same comm as the real
# RetroArch binary it forks (confirmed empirically, not assumed -- a script
# exec'd this way is not distinguishable from its target by name).  A
# name-based pkill/pgrep in gs-suspend.sh could therefore match either
# process.  This runs the REAL gs-suspend.sh (every other scenario stubs it
# out) against a "game" that never quits on its own, to prove the
# escalation kills only the tracked PID (GS_S_PID in the session file) and
# never gs-shim.sh's own process.
reset_case
cat > "${GS_OPT}/orig/retroarch" <<'STUB'
#!/bin/bash
echo "$*" >> "${WORK}/launches.log"
n=$(cat "${WORK}/ra.turn" 2>/dev/null || echo 1)
echo $(( n + 1 )) > "${WORK}/ra.turn"
action=$(sed -n "${n}p" "${WORK}/ra.plan")
if [ "${action}" = "hang" ]; then
  sleep 100
fi
[ "${action}" = "switch" ] && : > "${GS_RUN}/gs_switch"
exit 0
STUB
chmod +x "${GS_OPT}/orig/retroarch"

printf 'hang\nend\n' > "${WORK}/ra.plan"
printf 'launch|/roms/gba/Two.gba|/cores/mgba.so|retroarch\n' > "${WORK}/ui.plan"

"${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc >/dev/null 2>&1 &
shim_pid=$!

waited=0
while [ ! -s "${GS_RUN}/gs_session" ]; do
  [ "${waited}" -ge 50 ] && break
  sleep 0.1
  waited=$(( waited + 1 ))
done
real_pid="$(grep '^GS_S_PID=' "${GS_RUN}/gs_session" 2>/dev/null | cut -d= -f2)"

check "the session file recorded the real game's PID" \
      "$([ -n "${real_pid}" ] && echo yes || echo no)" "yes"
check "the tracked PID is actually alive before quitting" \
      "$(kill -0 "${real_pid}" 2>/dev/null && echo alive || echo gone)" "alive"

GS_QUIT_TIMEOUT=1 GS_SHOT_TIMEOUT=1 GS_RA_PORT=55355 \
  "${ROOT}/scripts/gs-suspend.sh" >/dev/null 2>&1

check "the hung game is actually terminated" \
      "$(kill -0 "${real_pid}" 2>/dev/null && echo alive || echo gone)" "gone"
check "gs-shim.sh's own process survives the escalation" \
      "$(kill -0 "${shim_pid}" 2>/dev/null && echo alive || echo gone)" "alive"

wait "${shim_pid}" 2>/dev/null
check "the switch continued into the next game rather than aborting the session" \
      "$(wc -l < "${WORK}/launches.log")" "2"
check "the second launch used the picked game" \
      "$(tail -1 "${WORK}/launches.log")" "-L /cores/mgba.so /roms/gba/Two.gba"

# --- 11. Game Switcher.sh freezes ES unconditionally too, no setting needed -
# Unlike gs-shim.sh's mid-game invocation, ES is genuinely alive and
# rendering when Game Switcher.sh is reached idle -- nothing else stops it
# from contending with the carousel for the display, so this must always
# freeze it, not just when some setting says to.  Runs the REAL
# Game Switcher.sh (stubbing the carousel binary to return straight to
# EmulationStation, reusing the systemctl/pgrep/sudo stubs from scenario 9).
reset_case
rm -f "${WORK}/sudo.log" "${GS_RUN}/gs_session"
cat > "${GS_OPT}/gameswitcher" <<'STUB'
#!/bin/bash
exit 10
STUB
chmod +x "${GS_OPT}/gameswitcher"

PATH="${SUDOBIN}:${PATH}" "${ROOT}/scripts/Game Switcher.sh" >/dev/null 2>&1
check "Game Switcher.sh freezes the real ES binary with no setting involved" \
      "$(grep -c -- 'kill -STOP 5001' "${WORK}/sudo.log")" "1"
check "Game Switcher.sh resumes it again on exit" \
      "$(grep -c -- 'kill -CONT 5001' "${WORK}/sudo.log")" "2"
rm -f "${GS_OPT}/gameswitcher"

# --- 12. GS_ES_FROZEN=1 stops gs-shim.sh from re-freezing ES itself --------
# Game Switcher.sh already froze ES before handing off to the emulator; if
# gs-shim.sh redid its own self-heal (CONT) + freeze (STOP) here too, that
# resume-then-refreeze blip would land right as the new game is trying to
# take the screen. GS_ES_FROZEN=1 (set by Game Switcher.sh -- see scenario
# 13) must skip both, leaving only the unconditional exit-trap CONT.
reset_case
rm -f "${WORK}/sudo.log"
printf 'end\n' > "${WORK}/ra.plan"
: > "${WORK}/ui.plan"
GS_ES_FROZEN=1 PATH="${SUDOBIN}:${PATH}" "${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc
check "GS_ES_FROZEN=1 skips the shim's own freeze" \
      "$(grep -c -- 'kill -STOP 5001' "${WORK}/sudo.log")" "0"
check "GS_ES_FROZEN=1 skips the shim's own self-heal resume too" \
      "$(grep -c -- 'kill -CONT 5001' "${WORK}/sudo.log")" "1"

# --- 13. Game Switcher.sh marks ES as already frozen for the emulator it
# launches, so the handoff above actually happens on the device. -----------
reset_case
rm -f "${WORK}/sudo.log" "${GS_RUN}/gs_session" "${WORK}/env.log"
cat > "${GS_OPT}/gameswitcher" <<'STUB'
#!/bin/bash
{
  echo "action=launch"
  echo "key=deadbeef"
  echo "emulator=retroarch"
  echo "core=/cores/snes9x.so"
  echo "rom=/roms/snes/One.sfc"
} > "${GS_RUN}/gs_choice"
exit 0
STUB
chmod +x "${GS_OPT}/gameswitcher"

cat > "${GS_BIN}/retroarch" <<'STUB'
#!/bin/bash
echo "GS_ES_FROZEN=${GS_ES_FROZEN:-unset}" >> "${WORK}/env.log"
exit 0
STUB
chmod +x "${GS_BIN}/retroarch"

PATH="${SUDOBIN}:${PATH}" "${ROOT}/scripts/Game Switcher.sh" >/dev/null 2>&1
check "Game Switcher.sh marks ES as already frozen for the emulator it launches" \
      "$(cat "${WORK}/env.log" 2>/dev/null)" "GS_ES_FROZEN=1"
rm -f "${GS_OPT}/gameswitcher"

# Restore the real shim before any further scenario calls "${GS_BIN}/retroarch"
# expecting gs-shim.sh's actual behavior, not the env-dumping stub above.
cp "${ROOT}/scripts/gs-shim.sh" "${GS_BIN}/retroarch"
chmod +x "${GS_BIN}/retroarch"

# --- 14. a failing launch is captured, not indistinguishable from a normal
# quit.  Round 11's bug report turned out to be RetroArch itself exiting
# almost immediately with no visibility into why -- gs-shim.sh now logs its
# exit code, how long it ran, and (when that looks like a failure) its
# captured output. ------------------------------------------------------
reset_case
rm -f "${GS_STATE}/gameswitcher.log"
cat > "${GS_OPT}/orig/retroarch" <<'STUB'
#!/bin/bash
echo "$*" >> "${WORK}/launches.log"
echo "some fatal init error" >&2
exit 7
STUB
chmod +x "${GS_OPT}/orig/retroarch"
: > "${WORK}/ui.plan"
GS_DEBUG=1 "${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc >/dev/null 2>&1
check "the failing exit code is logged" \
      "$(grep -c 'orig retroarch exited rc=7' "${GS_STATE}/gameswitcher.log")" "1"
check "its captured output is logged too" \
      "$(grep -c 'orig retroarch output:.*some fatal init error' "${GS_STATE}/gameswitcher.log")" "1"

# Restore the well-behaved stub so nothing downstream is affected.
cat > "${GS_OPT}/orig/retroarch" <<'STUB'
#!/bin/bash
echo "$*" >> "${WORK}/launches.log"
n=$(cat "${WORK}/ra.turn" 2>/dev/null || echo 1)
echo $(( n + 1 )) > "${WORK}/ra.turn"
action=$(sed -n "${n}p" "${WORK}/ra.plan")
if [ "${action}" = "hang" ]; then
  sleep 100
fi
[ "${action}" = "switch" ] && : > "${GS_RUN}/gs_switch"
exit 0
STUB
chmod +x "${GS_OPT}/orig/retroarch"

# --- 15. a launch-time crash is retried once, and a second attempt that
# succeeds lets the game actually run.  Confirmed on-device: RetroArch
# segfaults (SIGSEGV) right at launch when reached via the idle-Fn path,
# with a kernel-side DRM modeset (vop_crtc_enable) landing at the exact
# same moment -- a one-time collision with EmulationStation's still-held
# display state, not a persistent condition, so a second attempt should
# find a clean device. -------------------------------------------------
reset_case
rm -f "${GS_STATE}/gameswitcher.log" "${WORK}/crash.turn"
cat > "${GS_OPT}/orig/retroarch" <<'STUB'
#!/bin/bash
echo "$*" >> "${WORK}/launches.log"
n=$(cat "${WORK}/crash.turn" 2>/dev/null || echo 1)
echo $(( n + 1 )) > "${WORK}/crash.turn"
if [ "${n}" = "1" ]; then
  kill -SEGV $$
fi
exit 0
STUB
chmod +x "${GS_OPT}/orig/retroarch"
: > "${WORK}/ui.plan"
GS_DEBUG=1 "${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc >/dev/null 2>&1
check "a launch-time crash is retried" \
      "$(grep -c 'crashed right at launch, retrying' "${GS_STATE}/gameswitcher.log")" "1"
check "the game actually launched on the second attempt" \
      "$(wc -l < "${WORK}/launches.log")" "2"
check "the retried launch's own clean exit is logged with the right attempt number" \
      "$(grep -c 'exited rc=0 after.*(attempt 2)' "${GS_STATE}/gameswitcher.log")" "1"

# --- 16. a launch that keeps crashing gives up after exactly one retry --
# rather than looping forever if it's not a one-time collision after all.
reset_case
rm -f "${GS_STATE}/gameswitcher.log"
cat > "${GS_OPT}/orig/retroarch" <<'STUB'
#!/bin/bash
echo "$*" >> "${WORK}/launches.log"
kill -SEGV $$
STUB
chmod +x "${GS_OPT}/orig/retroarch"
: > "${WORK}/ui.plan"
GS_DEBUG=1 "${GS_BIN}/retroarch" -L /cores/snes9x.so /roms/snes/One.sfc >/dev/null 2>&1
check "a persistently crashing launch is attempted exactly twice" \
      "$(wc -l < "${WORK}/launches.log")" "2"
check "it gives up after the one retry rather than looping forever" \
      "$(grep -c 'retrying once' "${GS_STATE}/gameswitcher.log")" "1"
check "the second crash is still logged with its own attempt number" \
      "$(grep -c 'exited rc=139 after.*(attempt 2)' "${GS_STATE}/gameswitcher.log")" "1"

# Restore the well-behaved stub so the tree is left in a known state.
cat > "${GS_OPT}/orig/retroarch" <<'STUB'
#!/bin/bash
echo "$*" >> "${WORK}/launches.log"
n=$(cat "${WORK}/ra.turn" 2>/dev/null || echo 1)
echo $(( n + 1 )) > "${WORK}/ra.turn"
action=$(sed -n "${n}p" "${WORK}/ra.plan")
if [ "${action}" = "hang" ]; then
  sleep 100
fi
[ "${action}" = "switch" ] && : > "${GS_RUN}/gs_switch"
exit 0
STUB
chmod +x "${GS_OPT}/orig/retroarch"

exit "${FAIL}"
