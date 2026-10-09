# hifps

Ashita v4 addon that runs Final Fantasy XI above 60fps while keeping game speed tied to real time.

> Fixed along the way: lock-on camera (v0.2), late music and pushing through entities (v0.4), blur while turning the camera in motion (v0.5, v0.6), slow lock-on run animation (v0.7.3), other characters microstuttering (v0.8), NPCs sliding in their idle pose (v0.8.1), the target's name pulsing too fast (v0.9.4), other players seeing you walk in bursts when the frame rate is under the cap (v0.9.5). Check your server's rules on client modifications before using it.

## How it works

The client advances timers, animation and motion by a per-frame step measured in 1/60-second ticks. It reads that step through a getter that returns `max(step, 1.0)`, and the step normally comes from the fps divisor. So above 60fps every frame still counts as at least one full tick, and the game runs fast.

hifps:

- replaces both copies of the getter. One returns the real frame time in ticks (fractional), and the other returns whole ticks accumulated from real time (0, 1, 2...).
- points each of the 218 call sites at the right one: the 119 that truncate the step to an integer get whole ticks, and 90 get the fractional step. The one that adds the step to the movement count your client sends while you stand still gets the stock 1 tick.
- runs the per-tick smoothing loops once per frame and rescales their easing factors, per-tick amounts and delay timer to the real frame time: the camera's three (5 call sites: follow, ease, and distance/collision), so the camera moves every frame at the stock speed, and other characters' movement and turning (3 call sites), so they no longer move one or two passes a frame depending on whether the frame took longer than 1/60s.
- scales the walk/run animation's per-tick thresholds and smoothing to the frame's step, so slow walkers don't slide in their idle pose.
- scales the per-tick distance that counts as moving to the frame's step. Your client counts the ticks you spend moving and sends the count to the server, and other players' clients play your walk by it; a short frame used to start the count over mid-walk.
- gives the target's name pulse a count of whole 1/60s ticks from real time instead of the frame count.
- sets the fps divisor to 0 (uncapped) and caps the frame rate with its own QueryPerformanceCounter-based limiter.

It checks every call site before patching and refuses to patch if the client doesn't match. Unloading restores every original byte and the divisor.

## Install

Copy `hifps.lua` and `proxy_code.lua` to `<Ashita>\addons\hifps\`, then run `/addon load hifps`.

Settings are saved for all characters in `<Ashita>\config\addons\hifps\settings.lua`: on/off, the frame limit, the counter and the experimental toggles.

## Commands

| Command | Effect |
| --- | --- |
| `/hifps` | Open the config window: frame limit, counter, the experimental toggles. |
| `/hifps help` | Show status: fps, current step, limit, and the commands. |
| `/hifps limit <n>` | Set the frame cap (default 240). `0` removes it; use vsync or a driver cap instead. |
| `/hifps counter` | Show or hide the fps counter in the top-left corner (shown by default). |
| `/hifps off` / `/hifps on` | Restore the original code / re-apply the patch. |
| `/hifps exp` | List the experimental toggles and whether each is on. |
| `/hifps exp <name\|all> [on\|off]` | Turn an experimental toggle on or off (see below). |
| `/hifps exp ashita check` / `force` | Show what uses Ashita's draw events / turn `ashita` on anyway. |
| `/hifps mem` | The game's memory and how fast it grew over the last minute. |
| `/hifps leak start` / `stop` | Hunt for a memory leak above 60fps: a minute as usual, a minute with every call site on the stock step, then a bisect a minute a round. Stand still in a busy place; moving stops it. |
| `/hifps bisect start` | Start bisecting a bug. Half of the remaining call sites go back to the stock 60fps step. |
| `/hifps bisect fixed` / `broken` | Report whether the bug is gone or still there; repeat until it names a single call site. |
| `/hifps bisect stop` | End bisecting. |

While bisecting or hunting a leak, sites set back to stock run fast above 60fps. Only bisect on a local server.

## Experimental toggles

Off by default. None of them changes the game step, and each puts back what it changed when turned off, on `/hifps off` and on unload.

| Toggle | Effect |
| --- | --- |
| `ashita` | Skips Ashita's per-draw plugin dispatch (about 3,000 draws a frame are handed to every plugin and addon). The `d3d_dp`/`dip`/`dpup`/`dipup` events stop firing, so it first checks the loaded addons and plugins for users of them and refuses if it finds one, and turns itself off if one is loaded later. |
| `occlusion` | Characters' behind-a-wall test stalls the frame on a GPU readback every 4th frame. Above 60fps it runs every 4m-th frame instead (m = fps/60, rounded down to 1, 2, 4, 8 or 16), so a result is as fresh as at stock 60fps. |
| `sse` | The client only uses its SSE character skinning when the CPU says Intel; this turns it on for other CPUs. |
| `batch` | Text and UI draw one quad per call; consecutive quads with nothing changed between them become one draw. Same picture. |
| `dedupe` | About 40% of the client's device calls set a value already in effect; these are dropped. |

`batch` and `dedupe` swap a proxy vtable onto the client's device. Its code is `proxy_code.lua`, built from `proxy/proxy.asm` by `proxy/build.py` (MASM) and tested against a simulated device by `proxy/gen_harness.py`.

## Compatibility

Works alongside xicamera. If another addon changes the camera or character code in a way hifps can't adjust for, hifps prints a warning saying which part is affected.

Call-site offsets were taken from the PhoenixXI client's FFXiMain.dll. On any other client build, the addon refuses to patch.
