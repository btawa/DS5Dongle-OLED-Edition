# HANDOFF — fix the constant trigger buzz (#11) without losing #6

_Written 2026-06-05 on the laptop (no Pico on hand). Resume on the main PC with hardware._

**Status: design complete + agreed. NOT implemented, NOT built, NOT flashed.** This doc has the
full root-cause and the exact code so you can drop it in, build, and HIL-verify in one sitting.

---

## The decision (don't re-litigate this)

- **Ground truth for the whole project:** the dongle should make the DualSense behave **as close to a
  wired-USB controller as possible.** Every "should we add a setting?" gets answered with "does USB do
  it? then match that" — not a new toggle.
- **Keep the #6 adaptive-trigger fix.** Users have confirmed games work with it. It was correct.
- **#11 (constant trigger buzz) is an unintended side-effect of #6**, not a reason to revert it.
- **We rejected a toggle.** A toggle treats the symptom and makes you babysit it. We fix the cause.

---

## Root cause (verified against upstream `awalol/DS5Dongle`)

I fetched upstream and diffed the haptic path. Fork point: `0ed05d3` ("fix: rumble").

- **The only haptic-relevant deviation from upstream is #6** (`71cead4`): in `src/state_mgr.cpp` we added
  ```c
  set_bit(state[0], 2, update.AllowRightTriggerFFB);
  set_bit(state[0], 3, update.AllowLeftTriggerFFB);
  ```
  Upstream copies the trigger FFB *params* (its `copy_if_allowed` lines are identical to ours) but
  **never sets these two apply-bits**, so upstream's adaptive triggers are silently dead. We turned
  them on. That's the entire difference.
- **The re-broadcast is NOT our deviation.** Both upstream and our fork stamp the full controller state
  (`state_set(pkt+13, 63)`) into **every `0x36` audio frame** — it's load-bearing for keeping the
  speaker/HD-haptic actuators alive (the `0x7f 0x7f` volume bytes must ride every frame; see CLAUDE.md).
- **So the buzz = (our enabled trigger bits) × (the audio-rate re-broadcast).** A host-latched trigger
  effect gets re-commanded ~100×/second on the **audio clock**. Wired USB never does that — the host
  drives trigger updates on **its** clock and the controller latches the last effect.
- Upstream doesn't buzz only because it never enables triggers (and pays for it with dead triggers).
  Neither upstream (no triggers) nor our current master (buzzing triggers) matches USB. The fix below does.

`auto_haptics` (speaker-derived rumble) is a fork-only feature but is **off by default** — not the culprit.

---

## How state reaches the controller — the four egress points

| Site | Report | Cadence | Carries triggers today? |
|---|---|---|---|
| `src/main.cpp:322` | `0x31` | only on a host output report, **and only when audio is OFF** | yes (already USB-like) |
| `src/bt.cpp:636` | `0x32` | **once**, at L2CAP connect (init handshake) | init only; params are zero |
| `src/audio.cpp:172` | `0x36` | ~4 Hz keepalive (audio armed but idle) | yes — re-fires |
| `src/audio.cpp:404` | `0x36` | **~100 Hz** while audio streams | yes — re-fires (the loud buzz) |

Critical detail at `src/main.cpp:307-311`: **when audio is active the firmware deliberately does NOT send
the standalone `0x31`** — it lets the trigger FFB written into `state[]` "ride the `0x36` audio frames
instead." So during gameplay-with-audio, the 100 Hz `0x36` re-broadcast is the *only* trigger delivery
path. That is exactly the path that buzzes.

---

## The fix — one-shot trigger emit (mirrors USB cadence)

Deliver the trigger apply-bits **once per host update**, then go trigger-neutral so the controller
*latches* the effect instead of being re-hit by it. The `0x0C` apply-bits are literally named
"*Enable setting* RightTriggerFFB" — cleared means "leave triggers as-is," so the DS5 holds the last
applied effect (same as USB).

### `src/state_mgr.cpp`

1. Add a file-static one-shot (single-core: `state_update` and the frame senders all run on core 0, so
   no atomics needed):
   ```c
   static bool trigger_oneshot = false;   // armed by a host trigger write, consumed by the next outbound frame
   ```
2. In `state_update()`, right after the two existing `set_bit(state[0], 2/3, ...)` lines, arm it:
   ```c
   // Trigger FFB is a host-latched effect, not a continuous level: arm a one-shot so exactly ONE
   // outbound frame carries the apply-bits after each host update, then state_set_frame() masks them
   // off. The controller holds the latched effect instead of it being re-fired on every 0x36 audio
   // frame (the #11 buzz). Mirrors wired USB. Keeps #6 fully intact.
   if (update.AllowRightTriggerFFB || update.AllowLeftTriggerFFB) trigger_oneshot = true;
   ```
3. Add a new frame-copy next to `state_set()`:
   ```c
   // Like state_set(), but for REPEATING outbound frames (the 0x36 audio frames, the 0x31 host echo).
   // Emits the adaptive-trigger apply-bits only on the first frame after a host trigger update, then
   // clears them so the effect isn't re-fired at audio rate (#11). Rumble (bits 0/1) is a continuous
   // level and is intentionally left re-asserted every frame.
   void state_set_frame(uint8_t *data, const uint8_t size) {
       state_set(data, size);
       if (trigger_oneshot) trigger_oneshot = false;   // this frame carries the triggers
       else if (size > 0)   data[0] &= ~0x0C;           // clear AllowRight/LeftTriggerFFB → hold latched effect
   }
   ```

### `src/state_mgr.h`
Declare it:
```c
void state_set_frame(uint8_t *data, const uint8_t size);
```

### Swap the three *repeating* senders (leave `bt.cpp:636` init as plain `state_set`)
- `src/audio.cpp:172` → `state_set_frame(pkt + 13, 63);`
- `src/audio.cpp:404` → `state_set_frame(pkt + 13, 63);`
- `src/main.cpp:322` → `state_set_frame(outputData + 3, sizeof(SetStateData));`

### Why this is safe
- Additive + 3 one-line swaps; fully reversible.
- Can't break #6: every host trigger update still produces exactly one trigger-bearing frame to the DS5.
- Can't regress rumble: only byte-0 bits 2,3 are masked; rumble bits 0,1 still re-assert every frame.
- Worst case if the buzz had another cause: it's a no-op move toward USB cadence, not a regression.

### Offsets (already confirmed in `src/utils.h:289` `SetStateData`)
- byte 0 bit 2 = `AllowRightTriggerFFB`, bit 3 = `AllowLeftTriggerFFB` → mask `0x0C`.
- `RightTriggerFFB[11]` at state byte 10; `LeftTriggerFFB[11]` at byte 21. (Params don't need zeroing —
  the DS5 ignores them when the apply-bit is clear. Masking the apply-bit is sufficient.)

---

## Build + flash (main PC)

```bash
git fetch origin && git checkout master          # this fix branches off master (clean 0.6.12)
git checkout -b fix/trigger-ffb-latch
# ...apply the edits above...

# Toolchain (Ubuntu 26.04 — the apt install was started on the laptop, finish/verify it):
#   sudo apt-get install -y cmake ninja-build build-essential \
#     gcc-arm-none-eabi libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib python3 git
# Pico SDK 2.2.0 + export PICO_SDK_PATH, then PIN TinyUSB (or the audio config won't compile):
( cd "$PICO_SDK_PATH/lib/tinyusb" && git fetch --tags && git checkout 0.20.0 )

cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DPICO_SDK_PATH="$PICO_SDK_PATH"
cmake --build build --target ds5-bridge          # → build/ds5-bridge-oled.uf2
# BOOTSEL the board, copy the UF2 onto the RP2350 mount
```

## HIL verification (the part that actually needs the hardware)

1. **Triggers still work (#6 intact):** in a game with adaptive triggers (or the on-dongle Trigger Test
   screen), confirm resistance/effects still fire. Test **with audio active** specifically (that's the
   path we changed).
2. **Buzz is gone (#11):** set a trigger effect in a game, then idle — the constant low-level
   buzz/vibration should not persist.
3. **Decisive instrument:** OLED **Diagnostics** screen — watch the `trig` / `host02` counters during
   the buzz scenario. (These are `g_host_out02_trig_allow` / `_to_bt` / `_folded` from `src/main.cpp`.)
   Confirms whether the host is streaming trigger FFB vs a stale latch.
4. **Latch assumption check:** the fix relies on the DS5 holding the last effect when apply-bit=0. If an
   effect unexpectedly *clears* between updates, the assumption is wrong — fall back to "emit on change"
   (shadow-compare the trigger bytes) instead of the one-shot. (Not expected; apply-bit semantics say hold.)

Commit only after HIL passes (one-UF2-per-feature cadence). Trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Branch off master, push to `origin` only. Then it can ship as 0.6.12 (update `CHANGELOG.md [Unreleased]` → Fixed).

---

## Other open threads (unchanged, not blocking this)

- **`audio/speaker-rate-trim`** branch — experimental `SpkTrim` crackle sweep (#7). See `HANDOFF.md` on
  that branch. Separate work.
- **`defaults/usb-faithful`** branch — 1000 Hz polling + mic-off defaults; needs a soak-test before merge.
- **Toolchain install** was started on the laptop (Ubuntu 26.04, apt) but not finished/verified; Pico SDK
  not yet cloned there. The main PC presumably already has a working build env.

## One-paste kickoff for a fresh session on the main PC

> Read `HANDOFF-trigger-buzz.md`. We're keeping the #6 adaptive-trigger fix and removing its side-effect,
> the constant trigger buzz (#11), by delivering trigger FFB once per host update instead of re-firing it
> on every 0x36 audio frame — wired-USB cadence. The exact edits (a `state_set_frame` one-shot in
> `state_mgr.cpp` + three call-site swaps) are in the doc. Help me apply them on a branch off master,
> build the UF2, and run the HIL verification in the doc.
