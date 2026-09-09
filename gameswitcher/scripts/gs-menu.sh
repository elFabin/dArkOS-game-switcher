#!/bin/bash
#############################################################################
# gs-menu.sh - text fallback for the switcher carousel.
#
# Same contract as /opt/gameswitcher/gameswitcher: read recents.tsv, write the
# chosen game to /dev/shm/gs_choice, exit 0 for "launch this", 10 for "back to
# EmulationStation", 11 for "sleep".  Used wherever the SDL2 binary could not
# be built, so the feature never depends on a compiler being present.
#
# Built the way every other dArkOS tool is: dialog on tty1, driven by gptokeyb.
#############################################################################

# shellcheck disable=SC1090
. "${GS_COMMON:-/usr/local/bin/gs-common.sh}"

export TERM=linux
export DIALOGRC=/opt/inttools/noshadows.dialogrc
sudo chmod 666 /dev/tty1 2>/dev/null

height="15"
width="60"
if [ -r "${GS_HOME}/.config/.DEVICE" ]; then
  case "$(tr -d '\0' < "${GS_HOME}/.config/.DEVICE")" in
    RG503|RGB20PRO|MINILOONG) height="20"; width="70" ;;
  esac
fi

set_gptokeyb=""
start_controls() {
  if [ -z "$(pgrep -f gptokeyb)" ] && [ -z "$(pgrep -f oga_controls)" ]; then
    sudo chmod 666 /dev/uinput 2>/dev/null
    export SDL_GAMECONTROLLERCONFIG_FILE="/opt/inttools/gamecontrollerdb.txt"
    if [ "$(cat "${GS_HOME}/.config/.DEVICE" 2>/dev/null)" = "MINILOONG" ]; then
      export HOTKEY="guide"
    fi
    /opt/inttools/gptokeyb -1 "gs-menu.sh" -c "/opt/inttools/keys.gptk" >/dev/null 2>&1 &
    disown
    set_gptokeyb="Y"
  fi
}

stop_controls() {
  if [ -n "${set_gptokeyb}" ]; then
    pgrep -f gptokeyb | sudo xargs -r kill -9 2>/dev/null
    unset SDL_GAMECONTROLLERCONFIG_FILE
  fi
  printf '\033c' > /dev/tty1
}

# "1747910000" -> "5m ago"
gs_ago() {
  local delta=$(( $(date +%s) - $1 ))
  if   [ "${delta}" -lt 60 ];    then printf 'just now'
  elif [ "${delta}" -lt 3600 ];  then printf '%dm ago' "$(( delta / 60 ))"
  elif [ "${delta}" -lt 86400 ]; then printf '%dh ago' "$(( delta / 3600 ))"
  else printf '%dd ago' "$(( delta / 86400 ))"
  fi
}

gs_write_choice() {
  {
    printf 'action=%s\n' "$1"
    printf 'key=%s\n'      "$2"
    printf 'emulator=%s\n' "$3"
    printf 'core=%s\n'     "$4"
    printf 'rom=%s\n'      "$5"
  } > "${GS_CHOICE}"
  gs_fix_perm "${GS_CHOICE}"
}

gs_recents_seed
if [ ! -s "${GS_RECENTS}" ]; then
  stop_controls
  msgbox "No recent games yet.  Play something first and the switcher will remember it."
  exit 10
fi

printf '\033c' > /dev/tty1
start_controls
trap stop_controls EXIT

while true; do
  options=()
  keys=(); emus=(); cores=(); roms=(); titles=()
  n=0
  while IFS=$'\t' read -r key epoch emulator core system title rom; do
    [ -n "${rom}" ] || continue
    n=$(( n + 1 ))
    keys+=("${key}"); emus+=("${emulator}"); cores+=("${core}")
    roms+=("${rom}"); titles+=("${title}")
    options+=("${n}" "$(printf '%-34.34s %-8.8s %s' "${title}" "${system}" "$(gs_ago "${epoch}")")")
  done < "${GS_RECENTS}"

  options+=("S" "Sleep")
  options+=("E" "Back to EmulationStation")

  choice=$(dialog --backtitle "dArkOS Game Switcher" \
    --title "Recent Games" \
    --no-collapse --clear \
    --cancel-label "Select + Start to exit" \
    --menu "Pick up where you left off" "${height}" "${width}" 10 \
    "${options[@]}" 2>&1 > /dev/tty1)

  case "${choice}" in
    "")  exit 10 ;;
    E)   exit 10 ;;
    S)   exit 11 ;;
  esac

  idx=$(( choice - 1 ))
  [ "${idx}" -ge 0 ] && [ "${idx}" -lt "${n}" ] || continue

  action=$(dialog --backtitle "dArkOS Game Switcher" \
    --title "${titles[${idx}]}" \
    --no-collapse --clear \
    --cancel-label "Back" \
    --menu "What would you like to do?" 12 "${width}" 4 \
    "R" "Resume where you left off" \
    "N" "Start over (set the savestate aside)" \
    "D" "Remove from this list" 2>&1 > /dev/tty1)

  case "${action}" in
    R) gs_write_choice launch  "${keys[${idx}]}" "${emus[${idx}]}" "${cores[${idx}]}" "${roms[${idx}]}"; exit 0 ;;
    N) gs_write_choice restart "${keys[${idx}]}" "${emus[${idx}]}" "${cores[${idx}]}" "${roms[${idx}]}"; exit 0 ;;
    D) gs_write_choice remove  "${keys[${idx}]}" "${emus[${idx}]}" "${cores[${idx}]}" "${roms[${idx}]}"; exit 0 ;;
  esac
done
