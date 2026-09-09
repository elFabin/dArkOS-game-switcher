#!/bin/bash
#############################################################################
# run_tests.sh - exercise the Game Switcher off-device.
#
# The A10 Mini is not reachable from a build host, so everything that can be
# checked without it is checked here: the recents store, the shim's switch
# loop (against stubbed retroarch/nc/ffmpeg), the install/uninstall round
# trip, and a headless render of the carousel.
#############################################################################

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
isnt() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "did not expect [$3]"; fi; }
has()  { if printf '%s' "$2" | grep -qF "$3"; then ok "$1"; else bad "$1" "missing [$3] in [$2]"; fi; }

section() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
section "shell syntax"
# ---------------------------------------------------------------------------
for f in "${ROOT}"/scripts/* "${ROOT}"/install.sh "${ROOT}"/uninstall.sh; do
  case "${f}" in *.gptk) continue ;; esac
  if bash -n "${f}" 2>/dev/null; then ok "parses $(basename "${f}")"
  else bad "parses $(basename "${f}")"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
  for f in "${ROOT}"/scripts/*.sh "${ROOT}"/scripts/pause.sh.gs \
           "${ROOT}"/install.sh "${ROOT}"/uninstall.sh; do
    if shellcheck -S error -x "${f}" >/dev/null 2>&1; then ok "shellcheck $(basename "${f}")"
    else bad "shellcheck $(basename "${f}")" "$(shellcheck -S error -x "${f}" 2>&1 | head -5)"; fi
  done
fi

# ---------------------------------------------------------------------------
section "recents store"
# ---------------------------------------------------------------------------
STATE="${WORK}/state"
mkdir -p "${STATE}"
export GS_STATE="${STATE}" GS_HOME="${WORK}/home" GS_OPT="${WORK}/opt" GS_BIN="${WORK}/bin"
mkdir -p "${GS_HOME}" "${GS_OPT}" "${GS_BIN}"
# shellcheck disable=SC1090
. "${ROOT}/scripts/gs-common.sh"

is "gs_title strips the extension" "$(gs_title '/roms/snes/Chrono Trigger (USA).sfc')" 'Chrono Trigger (USA)'
is "gs_system reads the rom folder" "$(gs_system '/roms/snes/x.sfc')" 'snes'
is "gs_system handles the second SD" "$(gs_system '/roms2/psx/y.chd')" 'psx'
is "gs_system falls back"           "$(gs_system 'weird')" 'games'
is "gs_key is stable"               "$(gs_key /roms/a.smc)" "$(gs_key /roms/a.smc)"
isnt "gs_key differs per rom"       "$(gs_key /roms/a.smc)" "$(gs_key /roms/b.smc)"

gs_recents_add retroarch /cores/snes9x.so "/roms/snes/A.sfc"
gs_recents_add retroarch /cores/mgba.so   "/roms/gba/B.gba"
is "two games recorded" "$(wc -l < "${GS_RECENTS}")" "2"
is "newest game is first" "$(head -1 "${GS_RECENTS}" | cut -f7)" "/roms/gba/B.gba"

gs_recents_add retroarch /cores/snes9x.so "/roms/snes/A.sfc"
is "replaying dedupes"      "$(wc -l < "${GS_RECENTS}")" "2"
is "replaying promotes"     "$(head -1 "${GS_RECENTS}" | cut -f7)" "/roms/snes/A.sfc"

GS_MAX_RECENTS=3
for i in 1 2 3 4 5; do gs_recents_add retroarch /cores/c.so "/roms/nes/G${i}.nes"; done
is "list is capped" "$(wc -l < "${GS_RECENTS}")" "3"
is "cap keeps newest" "$(head -1 "${GS_RECENTS}" | cut -f7)" "/roms/nes/G5.nes"

gs_recents_remove "$(gs_key /roms/nes/G5.nes)"
is "remove drops the entry" "$(wc -l < "${GS_RECENTS}")" "2"
isnt "removed game is gone" "$(head -1 "${GS_RECENTS}" | cut -f7)" "/roms/nes/G5.nes"

# Titles with spaces and brackets must survive the TSV round trip intact.
gs_recents_add retroarch /cores/c.so "/roms/snes/Some Game (USA) [!].sfc"
is "awkward titles survive" "$(head -1 "${GS_RECENTS}" | cut -f6)" "Some Game (USA) [!]"

# Seeding from RetroArch's own history playlist.
rm -f "${GS_RECENTS}"
mkdir -p "${GS_HOME}/.config/retroarch/playlists/builtin" "${WORK}/roms"
: > "${WORK}/roms/Seeded.sfc"
cat > "${GS_HOME}/.config/retroarch/playlists/builtin/content_history.lpl" <<JSON
{ "version": "1.5", "items": [
  { "path": "${WORK}/roms/Seeded.sfc", "label": "Seeded", "core_path": "/cores/snes9x.so" },
  { "path": "${WORK}/roms/Missing.sfc", "label": "Missing", "core_path": "/cores/snes9x.so" } ] }
JSON
gs_recents_seed
is "seeds from content_history.lpl" "$(wc -l < "${GS_RECENTS}")" "1"
is "seeded rom path"  "$(head -1 "${GS_RECENTS}" | cut -f7)" "${WORK}/roms/Seeded.sfc"
is "seeded core path" "$(head -1 "${GS_RECENTS}" | cut -f4)" "/cores/snes9x.so"

gs_recents_seed
is "seeding is a no-op once populated" "$(wc -l < "${GS_RECENTS}")" "1"

# ---------------------------------------------------------------------------
section "shim switch loop"
# ---------------------------------------------------------------------------
"${HERE}/shim_case.sh" "${ROOT}" && ok "shim scenarios" || bad "shim scenarios"

# ---------------------------------------------------------------------------
section "install / uninstall round trip"
# ---------------------------------------------------------------------------
"${HERE}/install_case.sh" "${ROOT}" && ok "install round trip" || bad "install round trip"

# ---------------------------------------------------------------------------
section "carousel"
# ---------------------------------------------------------------------------
if [ -x "${ROOT}/gameswitcher" ]; then
  UI="${WORK}/ui"
  mkdir -p "${UI}/thumbs"
  printf 'k1\t100\tretroarch\t/cores/a.so\tsnes\tGame One\t/roms/snes/one.sfc\n' >  "${UI}/recents.tsv"
  printf 'k2\t90\tretroarch32\t/cores/b.so\tgba\tGame Two\t/roms/gba/two.gba\n'  >> "${UI}/recents.tsv"

  SDL_VIDEODRIVER=dummy "${ROOT}/gameswitcher" --state "${UI}" --size 640x480 \
      --dump "${UI}/frame.bmp" --out "${UI}/choice" >/dev/null 2>&1
  rc=$?
  is "headless render exits 'back'" "${rc}" "10"
  if [ -s "${UI}/frame.bmp" ]; then ok "a frame was rendered"; else bad "a frame was rendered"; fi

  # An empty list must not crash, and must still offer a way out.
  mkdir -p "${UI}-empty"
  SDL_VIDEODRIVER=dummy "${ROOT}/gameswitcher" --state "${UI}-empty" --size 640x480 \
      --dump "${UI}-empty/frame.bmp" >/dev/null 2>&1
  is "empty list exits cleanly" "$?" "10"
else
  printf '  skip carousel (binary not built; run make)\n'
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
