#!/bin/bash
#############################################################################
# uninstall.sh - put everything install.sh touched back the way it was.
#
# Usage:  ./uninstall.sh [--yes] [--root DIR]
#############################################################################

set -u

ASSUME_YES=""
ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES="y" ;;
    --root)   ROOT="${2%/}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "${ROOT}" ]; then SUDO=""; else SUDO="sudo"; fi

GS_USER="${GS_USER:-ark}"
GS_HOME="${GS_HOME:-/home/${GS_USER}}"

BIN="${ROOT}/usr/local/bin"
OPT="${ROOT}/opt/gameswitcher"
SYSMENU="${ROOT}/opt/system"
STATE="${ROOT}${GS_HOME}/.config/gameswitcher"
CFGBACKUP="${STATE}/retroarch-cfg.backup"

say() { printf '%s\n' "$*"; }

confirm() {
  [ -n "${ASSUME_YES}" ] && return 0
  [ -r /usr/local/bin/buttonmon.sh ] || return 0
  # shellcheck disable=SC1091
  . /usr/local/bin/buttonmon.sh
  printf '\nRemove the Game Switcher?'
  printf '\nPress A to continue.  Press B to exit.\n'
  while true; do
    Test_Button_A
    [ "$?" -eq 10 ] && return 0
    Test_Button_B
    [ "$?" -eq 10 ] && return 1
    sleep 0.2
  done
}

restore_cfg() {
  local file key old
  [ -r "${CFGBACKUP}" ] || return 0
  while IFS=$'\t' read -r file key old; do
    [ -n "${file}" ] && [ -f "${file}" ] || continue
    if [ -n "${old}" ]; then
      sed -i "s|^${key} = .*|${key} = \"${old}\"|" "${file}"
    else
      # The key was absent before we added it.
      sed -i "\|^${key} = |d" "${file}"
    fi
  done < "${CFGBACKUP}"
  rm -f "${CFGBACKUP}"
}

if ! confirm; then
  say "Nothing was changed."
  exit 0
fi

say "Removing the Game Switcher..."

for emulator in retroarch retroarch32; do
  if [ -e "${OPT}/orig/${emulator}" ]; then
    ${SUDO} cp -f "${OPT}/orig/${emulator}" "${BIN}/${emulator}"
    ${SUDO} chmod 777 "${BIN}/${emulator}"
  fi
done

if [ -e "${BIN}/pause.sh.gs-orig" ]; then
  ${SUDO} cp -f "${BIN}/pause.sh.gs-orig" "${BIN}/pause.sh"
  ${SUDO} chmod 777 "${BIN}/pause.sh"
  ${SUDO} rm -f "${BIN}/pause.sh.gs-orig"
fi

restore_cfg

${SUDO} rm -f "${BIN}/gs-common.sh" "${BIN}/gs-suspend.sh" "${BIN}/gs-menu.sh"
${SUDO} rm -f "${SYSMENU}/Game Switcher.sh"
${SUDO} rm -rf "${OPT}"
rm -f "${GS_RUN:-/dev/shm}"/gs_session "${GS_RUN:-/dev/shm}"/gs_switch \
       "${GS_RUN:-/dev/shm}"/gs_choice 2>/dev/null

# The recents list and its thumbnails are the player's, not ours: leave them
# so a reinstall picks up where it left off.  Say so rather than deleting.
say ""
say "Done.  RetroArch is back to its stock settings."
say "Your recent-games list is kept at ${GS_HOME}/.config/gameswitcher"
say "in case you reinstall; delete that folder to clear it."
[ -z "${ASSUME_YES}" ] && sleep 4
exit 0
