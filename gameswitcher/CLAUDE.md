# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Where this lives

This directory (`gameswitcher/`) is a self-contained addon inside a much
larger checkout of the dArkOS handheld-emulation OS build system (the repo
root has `build_*.sh` scripts for dozens of unrelated emulators/tools). The
git remote (`elFabin/dArkOS-game-switcher`) and every commit that matters
here touch only this directory plus one top-level integration script,
`build_gameswitcher.sh` — treat `gameswitcher/` as the project root for all
practical purposes, but check that top-level script too whenever files move.

It ships two ways:
- **Baked into the OS image**: `build_gameswitcher.sh` (repo root, sourced
  during the image build, after `finishing_touches.sh` and before
  `cleanup_filesystem.sh` strips the SDL2 headers) copies the payload to
  `/opt/gameswitcher/` and drops `Game Switcher Setup.sh` into
  `/opt/system/Advanced/`. Ships inactive, like dArkOS's own Quick Mode —
  nothing is hooked until the player runs that entry.
- **As a drop-in**: `make package` produces `dist/GameSwitcher.zip`,
  unzipped into `/roms/tools` and installed the same way.

Either way, **`Game Switcher Setup.sh`** (project root) is the actual
entry point end users hit — it's a toggle: `grep -q gs-shim
/usr/local/bin/retroarch` decides whether to `exec` `gs-install.sh` or
`gs-uninstall.sh`, found under `/opt/gameswitcher/scripts` if the image-baked
copy exists, else `/roms/tools/GameSwitcher/scripts` for a manual drop-in.

Target hardware is an **A10 Mini** (RK3326, 640x480, dArkOS/EmulationStation-fcamod).
There is no way to reach real hardware from a dev/build host — every fix in
this project's history was designed off logic first, then verified (or
disproved) against logs and `dmesg` the user pasted back from the device.
Don't assume a fix works until it's confirmed that way.

## Commands

```sh
make            # builds ./gameswitcher, the SDL2 carousel binary
make check      # builds it, then runs test/run_tests.sh
make package    # produces dist/GameSwitcher.zip, the on-device drop-in
make clean      # removes the built binary
```

`make check` already runs `bash -n` on every script, `python3 -m py_compile`
on `gs-hotkeyd.py`, and `shellcheck -S error -x` on every shell script
(skipped silently if `shellcheck` isn't installed) as its first section —
there's no need to invoke shellcheck separately after a normal `make check`.

Running a single test file directly (each takes the project root as `$1`
and is independently useful while iterating):
```sh
./test/shim_case.sh "$(pwd)"       # gs-shim.sh's switch loop, ES freeze, escalation safety
./test/install_case.sh "$(pwd)"    # scripts/gs-install.sh / gs-uninstall.sh round-trip on a --root staging tree
./test/hotkey_case.sh "$(pwd)"     # gs-hotkeyd.py's TapDetector state machine
```
All of it runs against stubs (`sudo`, `systemctl`, `pgrep`, RetroArch itself)
on PATH — nothing here talks to real hardware. `test/run_tests.sh` is the
umbrella that also headless-renders the carousel with `SDL_VIDEODRIVER=dummy`.

macOS dev note: the Makefile needs `sdl2-config` or `pkg-config sdl2` on
`PATH` (`brew install sdl2`); the test scripts use GNU `sed -i` and
`md5sum`, neither of which stock BSD/macOS ships — `brew install coreutils
gnu-sed` and prepend their `libexec/gnubin` to `PATH` for `make check`.

## Architecture

**The core trick.** dArkOS/EmulationStation launches a game with one shell
command it blocks on: `sudo perfmax %GOVERNOR% %ROM%; nice -n -19
/usr/local/bin/retroarch -L <core> %ROM%; sudo perfnorm`. `gs-install.sh`
replaces `/usr/local/bin/retroarch` (and `retroarch32`) with `gs-shim.sh`,
preserving the real wrapper at `/opt/gameswitcher/orig/<name>`. Because
`gs-shim.sh` loops internally — quit one game, show the carousel, launch
the next — ES never regains the screen mid-session; switching costs a game
launch, not an ES restart. `gs-shim.sh` branches on `basename "$0"` to
serve both `retroarch` and `retroarch32` under the one script.

**Everything hangs off `scripts/gs-common.sh`.** Sourced by every other
script (`GS_COMMON` env var lets tests override the path). Owns:
path/env defaults, `gameswitcher.conf` sourcing, the recents store (TSV at
`~/.config/gameswitcher/recents.tsv` — added-to and removed-from only;
there is no seeding from RetroArch's own history anymore, see History),
the session marker (`/dev/shm/gs_session`, what's currently playing — PID
included), the switch marker (`/dev/shm/gs_switch`), the ES
freeze/resume/watchdog trio, and `gs_log`/`gs_fix_perm`.

**The three ways in:**
- **Mid-game Fn tap or power-button short-press** → `gs-hotkeyd.py` (a
  per-game watcher `gs-shim.sh` starts/stops for the life of a session,
  matching by evdev capability rather than device name) or `pause.sh.gs`
  (only installed if `GS_TRIGGER` includes `power`) → `gs-suspend.sh`
  (screenshots the live frame over RetroArch's network-command port,
  renames the PNG straight into `thumbs/` — no `ffmpeg` conversion step;
  the carousel decodes PNG itself, see `src/png.h` — sends `QUIT` twice,
  escalates to `SIGTERM` after `GS_QUIT_TIMEOUT` — always against the
  tracked PID, never by name) → back into `gs-shim.sh`'s loop, which shows
  the carousel
  (`src/gameswitcher.c`, SDL2, falls back to `gs-menu.sh`'s `dialog` UI if
  the carousel can't be built/fails to start) and launches whatever was
  picked.
- **`Options > Game Switcher`** (`Game Switcher.sh`, project root) — opens
  the carousel directly from EmulationStation's own menu so recent games
  are reachable after a reboot, not just mid-session. Picking a game hands
  off to `/usr/local/bin/<emulator>` (the shim) exactly as a fresh
  ES-initiated launch would.
- **`Options > Advanced`** — `Game Switcher Setup.sh` (install/uninstall
  toggle), `Game Switcher Button.sh` (relearns the hotkey via
  `gs-hotkeyd.py --learn`), `Game Switcher Diagnostics.sh` (filtered
  summary of `gs-doctor.sh`'s full report).

**Settings** (`config/gameswitcher.conf`, shipped once, never overwritten
by a reinstall): `GS_TRIGGER` (`fn`/`power`/`both`), `GS_HOTKEY_CODE`/`GS_HOTKEY_DEVICE`,
`GS_SHOW_SPLASH`, `GS_QUIT_TIMEOUT`, `GS_SHOT_TIMEOUT`, `GS_MAX_RECENTS`,
`GS_RA_PORT`, `GS_TEARDOWN_MS`, `GS_DEBUG` (timestamped log to
`~/.config/gameswitcher/gameswitcher.log`).

## Hard-won invariants (don't relitigate these)

- **Never match RetroArch by name.** `gs-shim.sh` is installed as the file
  `retroarch`/`retroarch32` and directly exec'd by path, so the kernel gives
  its own process the *same `comm`* as the real RetroArch binary it forks
  and waits on (confirmed empirically, `TASK_COMM_LEN` truncation makes it
  worse for `emulationstation` too — 16 chars, one over the 15-char
  `/proc/PID/comm` limit). Any `pgrep -x`/`pkill -x` by name can hit either
  process. Everything here signals by tracked PID (`GS_S_PID` in the
  session file) or matches full cmdline with `pgrep -f`, never a bare name.
  A previous version's name-based kill in `gs-suspend.sh`'s escalation was
  killing `gs-shim.sh` itself — that was the actual cause of "EmulationStation
  flickers when switching," not anything ES was doing.
- **`gs_es_freeze`/`gs_es_resume` (SIGSTOP/SIGCONT on ES's real binary, not
  its systemd-tracked wrapper PID) only pauses ES's scheduling — it cannot
  make ES release its DRM master or GL context.** That release only happens
  inside EmulationStation-fcamod's own code (`Window::deinit(true)`,
  called by both `FileData::launchGame` and `GuiTools::launchTool` before
  every `system()` call it makes, `init(true)` after). Freezing ES is a
  correct, working defensive net for the mid-game switch loop (`gs-shim.sh`),
  where ES is separately guaranteed already-blocked in its own `system()`
  call regardless of the freeze. It is **not** a substitute for that deinit
  for anything reached outside ES's own call path — see the idle-Fn history
  below before ever reintroducing something like it.
- **`gs-hotkeyd.py` never grabs its input devices** (`EVIOCGRAB`) — a
  grabbed device would stop the game itself (or ES) from seeing the same
  input. It matches whichever device reports the target evdev code in its
  capabilities rather than a fixed device name, so a wrong `GS_HOTKEY_DEVICE`
  only narrows the search instead of breaking detection outright.
- A game process exiting doesn't mean its GPU/DRM context has finished
  tearing down — `gs_wait_for_teardown` gives it a brief, fixed window
  (`GS_TEARDOWN_MS`) before the switcher contends for the display. This
  used to be a loop polling `gs_ra_running` for up to 2s instead of a fixed
  sleep — but `gs_ra_running` is a name-based `pgrep -x retroarch`, and per
  the invariant above, `gs-shim.sh` itself matches that name. Called from
  *inside* the shim (which is exactly where this ran), the loop was seeing
  itself and could never go false — every switch silently paid its full 2s
  cap. `gs_ra_running` is still correct for callers outside the shim
  (`pause.sh.gs`, `gs-doctor.sh`), where "a shim session is up" is exactly
  what they want to know — just never call it from inside `gs-shim.sh`.
- **`nc -u -w1` blocks for its full timeout against a port that's actually
  listening** — it only returns instantly when nothing is listening (the
  kernel answers with ICMP port-unreachable), which is exactly the case
  off-device and exactly why this looked free in testing. Measured directly
  against a real listener: 1.004s per call, and `gs_ra_cmd` used to fire it
  up to three times per switch. `gs_ra_cmd` now writes to RetroArch's UDP
  command port via bash's own `/dev/udp/…` redirection (no fork, no wait),
  falling back to `nc` only if that's unavailable.

## Significant history (what was tried and reverted, and why)

Roughly chronological; read this before proposing something that sounds
like it should obviously work — several plausible-looking approaches here
were already tried and specifically disproved on real hardware.

1. **PID-tracking fix.** `gs-suspend.sh`'s escalation and `gs_ra_running`
   originally matched RetroArch by name. Fixed by writing the real game's
   PID into the session file at launch and always signaling/checking that
   PID directly — see "Hard-won invariants" above.
2. **ES freeze/resume/watchdog**, gated behind a `GS_ES_FREEZE` setting
   (default off), added as a safety net for the mid-game switch loop. Later
   made **unconditional** and the setting removed outright, per explicit
   user direction ("cleaner code, save a few if checks") once it was clear
   there was no real use case for leaving it off.
3. **A system-wide idle-in-ES Fn shortcut** (`gs-hotkeyd-idle.service`, a
   persistent systemd unit separate from the per-game watcher) was added so
   the carousel could open from EmulationStation's own idle menus, not just
   mid-game or via Options. It was **fully removed** after several rounds of
   chasing a real bug: picking a game from that idle carousel reliably
   segfaulted RetroArch. Root cause, confirmed by reading
   EmulationStation-fcamod's own source (`es-app/src/FileData.cpp`,
   `es-app/src/guis/GuiTools.cpp`) and a `dmesg` capture showing a kernel-side
   DRM modeset (`vop_crtc_enable`) landing at the exact moment of the crash:
   ES only releases its renderer/DRM context cleanly on its *own* launch
   code path (`Window::deinit(true)` before `system()`), which the idle path
   — running independently of ES via a separate systemd service — could
   never trigger. `SIGSTOP` freezing ES from outside cannot substitute for
   that deinit. A real fix would need either synthetic-input menu
   navigation (rejected: fragile, depends on the live sort position of every
   installed Options-menu script/folder) or patching and rebuilding
   EmulationStation-fcamod itself to add an external trigger for
   `GuiTools::launchTool()`'s exact sequence (rejected as out of scope for
   a drop-in addon). The Fn shortcut now only works mid-game; the carousel
   is otherwise only reachable via `Options > Game Switcher`, which was
   never actually broken (it already goes through ES's own `launchTool()`).
   `gs-install.sh` unconditionally cleans up any leftover
   `gs-hotkeyd-idle.service` from an install predating this reversion.
4. **Launch-failure diagnostics** added to `gs-shim.sh` while chasing the
   above (capture `orig`'s stdout/stderr, log its exit code and elapsed
   time) were kept after the revert — generically useful for diagnosing any
   future launch failure, not tied to the removed feature. A crash-retry
   loop added alongside them (retry once on a fault-signal exit) was
   removed with the rest of the idle-path machinery once it was clear the
   retry never helped a genuine DRM-handover collision.
5. **Layout restructure** (done directly on the device/by hand, outside
   this session): `install.sh`/`uninstall.sh` moved into `scripts/` as
   `gs-install.sh`/`gs-uninstall.sh`; `Game Switcher.sh`, `Game Switcher
   Button.sh`, and `Game Switcher Diagnostics.sh` moved *out* of `scripts/`
   to the project root, next to the pre-existing `Game Switcher Setup.sh`,
   which is now the real, wired-in install/uninstall toggle shipped to
   `/opt/system/Advanced/`. The RetroArch-history "seeding" feature
   (`gs_recents_seed`, populating an empty recents list on first install)
   was removed entirely, along with its tests. `video_gpu_screenshot`'s
   install-time default flipped from `"false"` to `"true"` (GPU capture
   instead of the core framebuffer, so shaders/overlays show up in
   thumbnails too). The restructure briefly left a few cross-file
   inconsistencies that have since been fixed (`build_gameswitcher.sh`
   copying from the old pre-move paths; `Game Switcher Setup.sh` checking
   for a `/opt/gameswitcher/payload` directory nothing ever creates instead
   of `/opt/gameswitcher` itself; a stray debug `echo`/top-level `return 0`
   left in `gs-install.sh`; `gs-doctor.sh`'s debug-log check testing
   `[ -n "${GS_DEBUG}" ]`, always true since it defaults to `"0"`, instead
   of `[ "${GS_DEBUG}" = "1" ]`) — all confirmed fixed as of the current
   tree; worth a rebuild + `make check` after any future path-shuffling to
   catch the same class of gap early (`make check` only exercises files
   under `gameswitcher/`, not `build_gameswitcher.sh` at the repo root, so
   that one needs eyeballing by hand after any move).
