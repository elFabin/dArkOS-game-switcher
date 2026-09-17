# dArkOS Game Switcher

An Onion OS-style Game Switcher for dArkOS. Tap Fn (center key) briefly while RetroArch is running: the game is snapshotted, and a carousel of your recent games
appears, each showing a screenshot of exactly where you left it. Pick one and
it resumes from that moment.

Built and tested against an **A10 Mini** (RK3326, 640x480). It should work on
any dArkOS device, but only the A10 Mini has been targeted deliberately.

## How it works

dArkOS launches a game with a single shell command that EmulationStation then
blocks on:

```
sudo perfmax %GOVERNOR% %ROM%; nice -n -19 /usr/local/bin/retroarch -L <core> %ROM%; sudo perfnorm
```

`/usr/local/bin/retroarch` is already a shell wrapper in stock dArkOS, so the
switcher replaces it with a loop. When a switch is requested, the loop quits
the emulator, shows the carousel, and launches the next game — all inside the
one command ES is waiting on. ES never gets the screen back, so switching
games costs a game launch rather than an ES restart.

```
Fn tap (clean, no combo) -> gs-hotkeyd.py -> gs-suspend.sh
                                               SCREENSHOT ---(udp 55355)--> RetroArch
                                               thumbnail  ---(rename)-----> thumbs/<key>.png
                                               QUIT       ---(udp 55355)--> RetroArch
                                                                           (writes <rom>.state.auto)
ES -> gs-shim -> [game] -> switch requested? -> carousel -> [next game] -> ...
                        -> normal quit?      -> back to EmulationStation
```

Resuming needs no special flag: `savestate_auto_load` picks up
`<rom>.state.auto` on the next launch. This is the same mechanism dArkOS's own
Quick Mode uses, which is why the two **cannot both be active**.

## Standalone Install

If you already have a working dArkOS install you can download the latest version from the [releases](https://github.com/elFabin/dArkOS-game-switcher/releases) page.
On the SD Card, unzip `GameSwitcher.zip` into `/roms/tools`, then run
**Options > Tools > Install Game Switcher**. Or from a shell:

```sh
./scripts/gs-install.sh --yes
```

The installer **refuses to run while Quick Mode is enabled** — both take over the
RetroArch savestate settings.
**Disable Quick Mode first.**

Inside of the GameSwitcher folder, you'll find several aditional tools:

| File | What it does |
|---|---|
| Game Switcher | Opens the Game Switcher |
| Game Switcher Button | Sets the button that will be used to open the GS from inside RetroArch content |
| Game Switcher Diagnostics | Displays some useful information about the current GS installation |
| Game Switcher Setup | Install/Uninstall the GS |

To remove it you can run the same Options entry, which turns into
the uninstaller once the switcher is active. Everything it changed is backed
up first and restored exactly. Or from a shell:

```sh
./scripts/gs-uninstall --yes
```

## Controls

Each recent game shows full-screen, native to whatever resolution
`gs-suspend.sh` captured it at (the device's own display resolution) — Left/Right swipes straight to the next/previous game's
screenshot, edge to edge. Title, system, and the button hints sit in a thin
overlay at the top and bottom rather than eating into the picture.

| Button | Action |
|---|---|
| Fn (tap, mid-game) | Snapshot the game and open the switcher |
| Left / Right | Swipe to the next/previous recent game |
| A | Resume where you left off |
| X | Start over (the auto savestate is moved aside, not deleted) |
| Y | Remove from the list |
| B | Back to EmulationStation |
| Start | Sleep |

Fn is the A10 Mini's `system_hk` button (evdev `BTN_TRIGGER_HAPPY5`, code
708). Only a *clean tap* opens the switcher — hold it and press something
else and that combo goes to ogage exactly as before (Fn+D-pad for
brightness, Fn+Volume for fine brightness, Fn+Power to shut down). The power
button itself is untouched: a short press still just suspends.

Fn **only works mid-game and for RetroArch content only**. The
carousel is also reachable idle in EmulationStation's own menus via
`Options > Game Switcher`.

On a device where Fn isn't code 708, use**Options > Advanced > Game Switcher Button** to relearn it — see
[Settings](#settings).

## What it changes

| Path | Change |
|---|---|
| `/usr/local/bin/retroarch`, `retroarch32` | Replaced by the shim; originals kept in `/opt/gameswitcher/orig/` |
| `~/.config/retroarch{,32}/retroarch.cfg` and `.bak` | `savestate_auto_save`, `savestate_auto_load`, `network_cmd_enable` on; `screenshots_in_content_dir`, `video_gpu_screenshot` on; `screenshot_directory` pointed at the switcher's folder. Previous values recorded for the uninstaller |
| `/opt/system/Game Switcher.sh` | New Options entry |
| `/opt/system/Advanced/Game Switcher Button.sh`, `Game Switcher Diagnostics.sh`, `Game Switcher Setup.sh` | New Advanced entries |
| `~/.config/gameswitcher/` | Recents list, thumbnails, screenshots, settings, log |

The `.bak` config is patched alongside the live one because dArkOS restores
settings from it.

## Settings

`~/.config/gameswitcher/gameswitcher.conf` holds the tunables, installed with
comments and never overwritten by a reinstall. Most take effect on the next
game launch with no reinstall needed — the two exceptions are called out
below.

- **`GS_HOTKEY_CODE`** / **`GS_HOTKEY_DEVICE`** — the Fn button's evdev code
  (708 by default, the A10 Mini's `system_hk`) and device name (blank matches
  any device that can emit the code). Use **Game Switcher Button** script to relearn these on a different device instead of editing
  them by hand.
- **`GS_SHOW_SPLASH`** (default `0`) — re-run `perfmax`'s launch splash when
  switching games. Off by default: it's a second DRM/KMS client
  (`image-viewer`) landing right in the handover between one game and the
  next, plus a `~/.asoundrc` deletion on rk3326 that only EmulationStation's
  own game-end hook restores.
- **`GS_QUIT_TIMEOUT`**, **`GS_SHOT_TIMEOUT`**, **`GS_MAX_RECENTS`**,
  **`GS_RA_PORT`** — as before.
- **`GS_TEARDOWN_MS`** (default `400`) — milliseconds to let a just-quit
  game's GPU/DRM context settle before the carousel contends for the
  display. Raise it if the carousel ever comes up black or garbled right
  after a switch.
- **`GS_DEBUG`** (default `0`) — log switches, screenshot attempts, UI starts
  and Fn taps, with timestamps, to `~/.config/gameswitcher/gameswitcher.log`.
  Turn on when reporting a problem; noisy for everyday use.

Run **`gs-doctor.sh`** over SSH (or **Game Switcher Diagnostics** for a short on-device summary) to see the six RetroArch config keys across all four config files, whether the network-command port answers,
whether `nc`/`python3` are present, the configured Fn code and
whether its watcher is running, and the tail of the debug log.

## Scope

RetroArch (64 and 32 bit) only, which covers most systems on dArkOS.
Standalone emulators — DraStic, PPSSPP, Dolphin, Flycast, BigPEmu — are left
completely alone. They have no network-command interface, so each would need its own
save-and-quit adapter.

## Layout

```
src/gameswitcher.c   the carousel (core SDL2 only)
src/font.h           baked-in glyph atlas, generated by tools/genfont.py
scripts/gs-shim.sh   the switch loop, installed over /usr/local/bin/retroarch
scripts/gs-suspend.sh  snapshot + quit, run by the Fn watcher (or pause.sh)
scripts/gs-hotkeyd.py  the Fn-tap watcher, started for the life of a game
                     by gs-shim.sh
scripts/gs-menu.sh   dialog fallback UI, used where the carousel can't be built
                     or fails to start
scripts/gs-doctor.sh Game Switcher diagnostics (config, tools, hotkey, log)
scripts/gs-common.sh shared helpers: the recents store, RetroArch commands,
                     the optional EmulationStation freeze
test/run_tests.sh    off-device test suite
```

The carousel deliberately links against **core SDL2 only**. dArkOS's
`cleanup_filesystem.sh` strips the SDL2_image and SDL2_ttf headers (and
zlib's) from the image while `needed_packages.txt` keeps `libsdl2-dev`, so
thumbnails are the PNGs RetroArch itself writes, decoded by a small bundled
loader (`src/png.h`) that resolves `libz.so.1` at runtime with `dlopen`
rather than linking zlib at build time, and text comes from the baked-in
font atlas. If no compiler is present, or
the carousel fails to start even after its retries, the installer/shim fall
back to the `dialog` menu, which needs nothing beyond what every other
dArkOS tool already uses.

## Tests

```sh
make && make check
```

Covers the recents store, the Fn-tap detector's clean-tap/combo/long-press
logic, the shim's switch loop (including the Fn watcher's lifecycle, the
carousel's fallback to the text menu, and the optional EmulationStation
freeze/resume, all against stubs), the install/uninstall round trip on a
staging tree, and a headless render of the UI. Nothing here can talk to a real device, so also
walk the on-device checklist below after installing.

There's no `/dev/uinput` in most build sandboxes to synthesize real button
presses with, so the tap/combo/long-press state machine
(`gs-hotkeyd.py`'s `TapDetector`) is factored out to take plain
`(code, value, time)` tuples and is exercised directly with those instead of
through a real input device — see `test/hotkey_case.sh`.
