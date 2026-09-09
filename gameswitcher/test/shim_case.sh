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
# leaves the switch marker behind the way gs-suspend.sh would.
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

# --- 5. pause.sh only intercepts when a RetroArch game is up ---------------
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

rm -f "${GS_RUN}/gs_session"
"${GS_BIN}/pause.sh"
check "no game running -> stock pause.sh" "$(cat "${WORK}/pause.result")" "stock"

# pgrep must see a live 'retroarch' for the hook to fire; fake one on PATH.
STUBBIN="${WORK}/stubbin"
mkdir -p "${STUBBIN}"
printf '#!/bin/bash\n[ "$*" = "-x retroarch" ] && exit 0\nexit 1\n' > "${STUBBIN}/pgrep"
chmod +x "${STUBBIN}/pgrep"
: > "${GS_RUN}/gs_session"
PATH="${STUBBIN}:${PATH}" "${GS_BIN}/pause.sh"
check "game running -> switcher" "$(cat "${WORK}/pause.result")" "switcher"

exit "${FAIL}"
