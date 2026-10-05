# hifps

Ashita v4 addon that runs Final Fantasy XI above 60fps while keeping game speed tied to real time.

> Fixed along the way: lock-on camera (v0.2), late music and pushing through entities (v0.4), blur while turning the camera in motion (v0.5, v0.6), slow lock-on run animation (v0.7.3). Check your server's rules on client modifications before using it.

## How it works

The client advances timers, animation and motion by a per-frame step measured in 1/60-second ticks. It reads that step through a getter that returns `max(step, 1.0)`, and the step normally comes from the fps divisor. So above 60fps every frame still counts as at least one full tick, and the game runs fast.

hifps:

- replaces both copies of the getter. One returns the real frame time in ticks (fractional), and the other returns whole ticks accumulated from real time (0, 1, 2...).
- points each of the 218 call sites at the right one: the 120 that truncate the step to an integer get whole ticks, and 93 get the fractional step.
- runs the camera's three per-tick loops (5 call sites: follow, ease, and distance/collision) once per frame and rescales their easing factors, per-tick amounts and delay timer to the real frame time, so the camera moves every frame at the stock speed.
- sets the fps divisor to 0 (uncapped) and caps the frame rate with its own QueryPerformanceCounter-based limiter.

It checks every call site before patching and refuses to patch if the client doesn't match. Unloading restores every original byte and the divisor.

## Install

Copy `hifps.lua` to `<Ashita>\addons\hifps\hifps.lua`, then run `/addon load hifps`.

## Commands

| Command | Effect |
| --- | --- |
| `/hifps` | Show status: fps, current step, limit. |
| `/hifps limit <n>` | Set the frame cap (default 120). `0` removes it; use vsync or a driver cap instead. |
| `/hifps counter` | Show or hide the fps counter in the top-left corner (shown by default). |
| `/hifps off` / `/hifps on` | Restore the original code / re-apply the patch. |
| `/hifps bisect start` | Start bisecting a bug. Half of the remaining call sites go back to the stock 60fps step. |
| `/hifps bisect fixed` / `broken` | Report whether the bug is gone or still there; repeat until it names a single call site. |
| `/hifps bisect stop` | End bisecting. |

While bisecting, sites set back to stock run fast above 60fps. Only bisect on a local server.

## Compatibility

Works alongside xicamera. If another addon changes the camera code in a way hifps can't adjust for, hifps prints a camera warning saying which part is affected.

Call-site offsets were taken from the PhoenixXI client's FFXiMain.dll. On any other client build, the addon refuses to patch.
