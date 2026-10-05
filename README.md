# hifps

Experimental Ashita v4 addon that runs Final Fantasy XI above 60fps while keeping game speed tied to real time.

> **Experimental.** Fixed so far: lock-on camera (v0.2), late music and pushing through entities (v0.4). Some game systems may still behave differently from a stock client. Test on a local server before using it anywhere else, and check your server's rules on client modifications.

## How it works

The client advances timers, animation and motion by a per-frame step measured in 1/60-second ticks. It reads that step through a getter that returns `max(step, 1.0)`, and the step normally comes from the fps divisor. So above 60fps every frame still counts as at least one full tick, and the game runs fast.

hifps:

- replaces both copies of the getter. One returns the real frame time in ticks (fractional), and the other returns whole ticks accumulated from real time (0, 1, 2...).
- points each of the 218 call sites at the right one: the 126 that truncate the step to an integer get whole ticks, and the rest get the fractional step.
- sets the fps divisor to 0 (uncapped) and caps the frame rate with its own QueryPerformanceCounter-based limiter.

It checks every call site before patching and refuses to patch if the client doesn't match. Unloading restores every original byte and the divisor.

## Install

Copy `hifps.lua` to `<Ashita>\addons\hifps\hifps.lua`, then run `/addon load hifps`.

## Commands

| Command | Effect |
| --- | --- |
| `/hifps` | Show status: fps, current step, limit. |
| `/hifps limit <n>` | Set the frame cap (default 120). `0` removes it; use vsync or a driver cap instead. |
| `/hifps off` / `/hifps on` | Restore the original code / re-apply the patch. |
| `/hifps bisect start` | Start bisecting a bug. Half of the remaining call sites go back to the stock 60fps step. |
| `/hifps bisect fixed` / `broken` | Report whether the bug is gone or still there; repeat until it names a single call site. |
| `/hifps bisect stop` | End bisecting. |

While bisecting, sites set back to stock run fast above 60fps. Only bisect on a local server.

## Compatibility

Call-site offsets were taken from the PhoenixXI client's FFXiMain.dll. On any other client build, the addon refuses to patch.
