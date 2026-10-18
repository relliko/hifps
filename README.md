# hifps

Ashita v4 addon that runs Final Fantasy XI above 60fps while keeping game speed tied to real time.

> Fixed along the way: lock-on camera (v0.2), late music and pushing through entities (v0.4), blur while turning the camera in motion (v0.5, v0.6), slow lock-on run animation (v0.7.3), other characters microstuttering (v0.8), NPCs sliding in their idle pose (v0.8.1), the target's name pulsing too fast (v0.9.4), other players seeing you walk in bursts when the frame rate is under the cap (v0.9.5). Since v0.9.7 it can also brighten nights (lamp light, moonlight and shadow fill), and it keeps working when a client update moves the code it patches. Check your server's rules on client modifications before using it.

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

It checks every call site before patching. Unloading restores every original byte and the divisor.

## Install

Copy `hifps.lua`, `sites.lua`, `sigs.lua`, `proxy_code.lua`, `vis_code.lua` and `gfx_code.lua` to `<Ashita>\addons\hifps\`, then run `/addon load hifps`.

Settings are saved for all characters in `<Ashita>\config\addons\hifps\settings.lua`: on/off, the frame limit, the counter, the experimental toggles and the graphics settings.

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
| `/hifps gfx` | Show the graphics settings (see below). |
| `/hifps gfx lamps <brightness> [reach]` | Lamp light at night: brightness 0.5-3, reach 1-2 (1 = stock). |
| `/hifps gfx night <moonlight> [fill]` | Night lighting: moonlight and shadow fill, 0.5-2.5 (1 = stock). |
| `/hifps gfx stock` | All graphics settings back to stock. |
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
| `glows` | Glows, the sun's lens flare and doors run the same test every frame (at night up to 10 a frame, 100-330 µs each). Keeps each result for as many frames as 4 at 60fps for glows and the flare (4m frames above 60fps), and for doors as many as 1 at 60fps (m frames), so doors, which targeting reads, are as fresh as at stock 60fps. Re-tests are spread over the frames. |
| `sse` | The client only uses its SSE character skinning when the CPU says Intel; this turns it on for other CPUs. |
| `batch` | Text and UI draw one quad per call; consecutive quads with nothing changed between them become one draw. Same picture. |
| `dedupe` | About 40% of the client's device calls set a value already in effect; these are dropped. |

`batch` and `dedupe` swap a proxy vtable onto the client's device. Its code is `proxy_code.lua`, built from `proxy/proxy.asm` by `proxy/build.py` (MASM) and tested against a simulated device by `proxy/gen_harness.py`.

`glows` points the four calls at `vis_code.lua`, built from `proxy/vis.asm` by the same `proxy/build.py`.

## Graphics

Stock by default; in the config window's Graphics section or with `/hifps gfx`. Like everything else, they're put back on `/hifps off` and on unload.

| Setting | Effect |
| --- | --- |
| `lamps` | How bright lamps and torches are at night, on the ground, walls and the characters near them. |
| `reach` | How far lamp light reaches. The game lights a surface fully up to a lamp's range and not past it, so this makes the pools of light bigger with the same edge. Characters keep the stock reach. |
| `moon` | How bright the moon lights the ground, buildings and characters at night. |
| `fill` | How much light fills the sides the moon doesn't reach at night (the ambient light): less murky nights, while lamps still stand out and the sky stays dark. |

The lamp settings point the client's three lamp paths (the zone shader's lamp constants, the fixed-function lamp lights and a character's lamp-lit light) at `gfx_code.lua`, built from `proxy/gfx.asm`. The night settings hook the two functions every sun/moon light and ambient colour comes from, so the zone, characters and effects all follow. They apply fully from 20:00 to 4:00 Vana'diel time, ease in from 17:00 and out by 7:00, and leave daytime alone.

`proxy/test_stubs.py` runs the exact bytes of `vis_code.lua` and `gfx_code.lua` against fakes of what the client calls (32-bit MSVC).

## Compatibility

Works alongside xicamera. If another addon changes the camera or character code in a way hifps can't adjust for, hifps prints a warning saying which part is affected.

Call-site offsets were taken from the PhoenixXI client's FFXiMain.dll. When a client update moves code, hifps finds them again by byte signature (`sigs.lua`, built by `tools/gen_sigs.py` from a dump of that client). Calls to the step getter that it doesn't know get whole ticks, which keeps game time right. A smoothing loop it can't find runs as if another addon had changed it, with the same warning. `tools/check_client.py <dump>` loads hifps against a client dump offline; `--shift <offset> <bytes>` simulates an update.
