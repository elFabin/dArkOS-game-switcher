# dArkOS Game Switcher

An Onion OS-style Game Switcher for dArkOS. Tap Fn briefly while a RetroArch
game is running: the game is snapshotted, and a carousel of your recent games
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
                                               thumbnail  ---(ffmpeg)-----> thumbs/<key>.bmp
                                               QUIT       ---(udp 55355)--> RetroArch
                                                                           (writes <rom>.state.auto)
ES -> gs-shim -> [game] -> switch requested? -> carousel -> [next game] -> ...
                        -> normal quit?      -> back to EmulationStation
```

Resuming needs no special flag: `savestate_auto_load` picks up
`<rom>.state.auto` on the next launch. This is the same mechanism dArkOS's own
Quick Mode uses, which is why the two cannot both be active.

## Installing

On the device, unzip `GameSwitcher.zip` into `/roms/tools`, then run
**Options > Tools > Install Game Switcher**. Or from a shell:

```sh
./install.sh
```

Build the drop-in from a checkout with `make package`.

The installer refuses to run while Quick Mode is enabled — both take over the
RetroArch savestate settings (and `pause.sh`, if you use the power trigger).
Disable Quick Mode first.

To remove it: `./uninstall.sh`, or the same Options entry, which turns into
the uninstaller once the switcher is active. Everything it changed is backed
up first and restored exactly.

## Controls

Each recent game shows full-screen, native to whatever resolution
`gs-suspend.sh` captured it at (the device's own display resolution, not a
fixed low size) — Left/Right swipes straight to the next/previous game's
screenshot, edge to edge. Title, system, and the button hints sit in a thin
overlay at the top and bottom rather than eating into the picture.

| Button | Action |
|---|---|
| Fn (tap, in game) | Snapshot the game and open the switcher |
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

A/B/X/Y above are the buttons printed on the case, whatever their physical
position — `/opt/inttools/gamecontrollerdb.txt` binds SDL's canonical button
names directly to each device's own printed labels (confirmed across every
controller dArkOS recognizes, not just this one), so `SDL_CONTROLLER_BUTTON_A`
always means "the button labeled A." On a device where Fn isn't code 708, use
**Options > Advanced > Game Switcher Button** to relearn it — see
[Settings](#settings).

## What it changes

| Path | Change |
|---|---|
| `/usr/local/bin/retroarch`, `retroarch32` | Replaced by the shim; originals kept in `/opt/gameswitcher/orig/` |
| `/usr/local/bin/pause.sh` | Only touched if `GS_TRIGGER` includes `power` — see [Settings](#settings). Original kept as `pause.sh.gs-orig` |
| `~/.config/retroarch{,32}/retroarch.cfg` and `.bak` | `savestate_auto_save`, `savestate_auto_load`, `network_cmd_enable` on; `screenshots_in_content_dir`, `video_gpu_screenshot` off; `screenshot_directory` pointed at the switcher's folder. Previous values recorded for the uninstaller |
| `/opt/system/Game Switcher.sh` | New Options entry |
| `/opt/system/Advanced/Game Switcher Button.sh`, `Game Switcher Diagnostics.sh` | New Advanced entries |
| `~/.config/gameswitcher/` | Recents list, thumbnails, screenshots, settings, log |

The `.bak` config is patched alongside the live one because dArkOS restores
settings from it.

`screenshots_in_content_dir` is the reason screenshots didn't show up before
this key was added: it silently overrides `screenshot_directory`, so
RetroArch was writing the PNG next to the ROM instead of where the switcher
was looking — and worse, `.png` is also PICO-8's ROM extension, so leaving it
on risks EmulationStation scraping a screenshot as a cart.

## Settings

`~/.config/gameswitcher/gameswitcher.conf` holds the tunables, installed with
comments and never overwritten by a reinstall. Most take effect on the next
game launch with no reinstall needed — the two exceptions are called out
below.

- **`GS_TRIGGER`** (`fn` / `power` / `both`, default `fn`) — what opens the
  switcher. Switching *to* `power` or `both` needs a reinstall (it has to
  hook the system `pause.sh`); switching back to `fn` alone takes effect
  immediately.
- **`GS_HOTKEY_CODE`** / **`GS_HOTKEY_DEVICE`** — the Fn button's evdev code
  (708 by default, the A10 Mini's `system_hk`) and device name (blank matches
  any device that can emit the code). Use **Options > Advanced > Game
  Switcher Button** to relearn these on a different device instead of editing
  them by hand.
- **`GS_SHOW_SPLASH`** (default `0`) — re-run `perfmax`'s launch splash when
  switching games. Off by default: it's a second DRM/KMS client
  (`image-viewer`) landing right in the handover between one game and the
  next, plus a `~/.asoundrc` deletion on rk3326 that only EmulationStation's
  own game-end hook restores.
- **`GS_ES_FREEZE`** (default `0`) — `SIGSTOP` EmulationStation for the life
  of the switch loop and `SIGCONT` it on every exit path, including a crash
  (a background watchdog resumes it even if the shim is killed outright).
  Independent hardening for genuine display-handover timing; not needed for
  EmulationStation visibly appearing during switches, which had a different
  cause — see [If EmulationStation still appears to "take
  over"](#if-emulationstation-still-appears-to-take-over).
- **`GS_QUIT_TIMEOUT`**, **`GS_SHOT_TIMEOUT`**, **`GS_MAX_RECENTS`**,
  **`GS_RA_PORT`** — as before.
- **`GS_DEBUG`** (default `0`) — log switches, screenshot attempts, UI starts
  and Fn taps, with timestamps, to `~/.config/gameswitcher/gameswitcher.log`.
  Turn on when reporting a problem; noisy for everyday use.

Run **`gs-doctor.sh`** over SSH (or **Options > Advanced > Game Switcher
Diagnostics** for a short on-device summary) to see the six RetroArch config
keys across all four config files, whether the network-command port answers,
whether `ffmpeg`/`nc`/`python3` are present, the configured Fn code and
whether its watcher is running, and the tail of the debug log.

## If EmulationStation still appears to "take over"

This was root-caused on real hardware, and it was never actually
EmulationStation misbehaving: it was our own force-kill escalation killing
the switch loop itself.

`gs-shim.sh` is installed as the file `/usr/local/bin/retroarch` and
launched directly by that path (`nice -n -19 /usr/local/bin/retroarch
...`). The kernel sets a directly-exec'd script's `comm` to its own
basename, so `gs-shim.sh`'s own process is indistinguishable by name from
the real RetroArch binary it forks and waits on — both are "retroarch" as
far as anything matching by name can tell. `gs-suspend.sh` used to check
for and kill RetroArch by name (`pgrep -x`/`pkill -x retroarch`), which
meant its "RetroArch didn't quit in time" escalation could just as easily
kill `gs-shim.sh` itself as the actual game. When that happened,
`gs-shim.sh` died mid-session — running its cleanup trap (which resumes
EmulationStation, correctly, for exactly this kind of unexpected exit) and
leaving nothing to show the carousel. With the switch loop gone, the outer
command EmulationStation was blocked on simply finished, handing control
back to it completely normally. That's what looked like EmulationStation
"taking over": it wasn't a stale frame, a race, or ES doing anything
wrong — EmulationStation was legitimately regaining control because, as
far as it could tell from outside, the game had just ended.

This is fixed now: `gs-shim.sh` tracks the real game process's own PID
(written to the session file) and `gs-suspend.sh` checks and kills that
PID directly, never by name, so it can no longer touch `gs-shim.sh`'s own
process regardless of what name they happen to share. As a side effect,
switches that get a clean `QUIT` response should also feel snappier —
the old name-based check could never actually observe a clean quit (it
was always seeing `gs-shim.sh` itself as "still running"), so it always
waited out the full `GS_QUIT_TIMEOUT` before escalating, every switch,
regardless of the game.

`GS_ES_FREEZE` and the carousel's black-frame-first startup (see
`gameswitcher.c`) are both still in place as independent hardening for
genuine display-handover timing, but neither was the actual cause here.

If it still happens after this fix, set `GS_DEBUG=1` and reproduce it;
`gameswitcher.log` will show `gs_es_resume`/`gs_es_freeze` firing (or not)
and `ps -eo pid,ppid,stat,cmd | grep -i emulationstation` (use `cmd`, not
`comm` — the latter truncates "emulationstation" to 15 characters and
won't match a plain grep for the full name) will show the real process
tree at the moment it happens.

## Scope

RetroArch (64- and 32-bit) only, which covers most systems on dArkOS.
Standalone emulators — DraStic, PPSSPP, Dolphin, Flycast, BigPEmu — are left
completely alone: a power press during one of those suspends the device as it
always did. They have no network-command interface, so each would need its own
save-and-quit adapter.

## Layout

```
src/gameswitcher.c   the carousel (core SDL2 only)
src/font.h           baked-in glyph atlas, generated by tools/genfont.py
scripts/gs-shim.sh   the switch loop, installed over /usr/local/bin/retroarch
scripts/gs-suspend.sh  snapshot + quit, run by the Fn watcher (or pause.sh)
scripts/gs-hotkeyd.py  the Fn-tap watcher, started for the life of a game
scripts/gs-menu.sh   dialog fallback UI, used where the carousel can't be built
                     or fails to start
scripts/gs-doctor.sh Game Switcher diagnostics (config, tools, hotkey, log)
scripts/gs-common.sh shared helpers: the recents store, RetroArch commands,
                     the optional EmulationStation freeze
test/run_tests.sh    off-device test suite
```

The carousel deliberately links against **core SDL2 only**. dArkOS's
`cleanup_filesystem.sh` strips the SDL2_image and SDL2_ttf headers from the
image while `needed_packages.txt` keeps `libsdl2-dev`, so thumbnails are BMPs
written by `ffmpeg` and text comes from the baked-in font atlas. If no
compiler is present, or the carousel fails to start even after its retries,
the installer/shim fall back to the `dialog` menu, which needs nothing beyond
what every other dArkOS tool already uses.

## Tests

```sh
make && make check
```

Covers the recents store, the Fn-tap detector's clean-tap/combo/long-press
logic, the shim's switch loop (including the Fn watcher's lifecycle, the
carousel's fallback to the text menu, and the optional EmulationStation
freeze/resume, all against stubs), the install/uninstall round trip on a
staging tree (including switching `GS_TRIGGER` between `fn` and `power`), and
a headless render of the UI. Nothing here can talk to a real device, so also
walk the on-device checklist below after installing.

There's no `/dev/uinput` in most build sandboxes to synthesize real button
presses with, so the tap/combo/long-press state machine
(`gs-hotkeyd.py`'s `TapDetector`) is factored out to take plain
`(code, value, time)` tuples and is exercised directly with those instead of
through a real input device — see `test/hotkey_case.sh`.

## On-device checklist

Already confirmed working: the carousel builds and runs, Fn opens it, a
screenshot is captured from RetroArch (the PNG lands correctly) — what's
left to check is everything downstream of that plus the two other fixes in
this round:

1. Reinstall, then tap Fn on a running game — a thumbnail should now appear
   (was failing at the ffmpeg conversion step; check `gameswitcher.log`
   with `GS_DEBUG=1` if it still doesn't, which will now show ffmpeg's own
   error message instead of a bare exit code).
2. Press each of A/B/X/Y and confirm the action matches the printed label
   (A=resume, B=back, X=start over, Y=remove) — this was inverted before;
   the fix couldn't be tested off-device, so this is the one to watch most
   closely.
3. Switch between games a few times, including at least one where you leave
   a game idling long enough that it might not respond to `QUIT`
   instantly — EmulationStation should no longer appear during the gap
   (root cause was gs-suspend.sh's force-kill escalation killing the switch
   loop's own process; fixed by tracking the real game's PID directly), and
   a clean quit should now feel noticeably faster than before.
4. Pick a second game; go back to the first — it should resume where you left.
5. "Back to EmulationStation" should return to a responsive ES, not a restart.
6. Quit a game normally (Select+Start) — should behave exactly as before.
7. Fn+D-pad brightness, Fn+Volume, and Fn+Power (shutdown) should all still
   work — the clean-tap rule is what protects them from the switcher.
8. A plain power press should suspend, both in EmulationStation and mid-game.
9. Power press inside DraStic still suspends — no regression for standalones.
10. `./uninstall.sh`, then confirm RetroArch no longer writes `.state.auto`.
