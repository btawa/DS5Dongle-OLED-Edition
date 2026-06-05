# HANDOFF — audio work in progress

_Last updated: 2026-06-04 (written on the laptop; continuing on the main PC)_

This is a working handoff so the next session — on the main PC, or a fresh Claude Code
session — can pick up exactly where we left off. **All the real work is committed and pushed
to `origin`; nothing is stuck on the laptop.** This file lives on the `audio/speaker-rate-trim`
branch, so after `git checkout audio/speaker-rate-trim` it's right here.

---

## TL;DR

- The frustration that kicked this off: **audio (speaker/mic/HD haptics) is the priority**, not OLED features. Goal: make the dongle behave **as close to a wired-USB DualSense as possible**, with flaky extras opt-in.
- We confirmed the open GitHub issues are real, synced the tree up to **v0.6.11** (it was stale at 0.6.4), and split the work onto two feature branches.
- **Main thing to do next:** build `audio/speaker-rate-trim` on the main PC, flash it, and run the **`SpkTrim` sweep test** (below) to find out whether the speaker crackle is a fixed clock offset (curable with the new knob) or live drift (needs adaptive resampling).

---

## Branch map

| Branch | Commit | State | Needs |
|---|---|---|---|
| `master` | `878a742` | untouched, = `origin/master` = **v0.6.11** | — |
| `defaults/usb-faithful` | `333201e` | pushed | **HIL soak-test** before merging to master |
| `audio/speaker-rate-trim` | `3b157cb` | pushed | **build + flash + sweep test** (not yet built) |

Both feature branches are pushed to `origin` (the fork) and tracking. `upstream` / `upstream-fork` were **not** touched.

---

## What each branch contains

### `defaults/usb-faithful` — out-of-box "acts like USB" defaults
A full audit found the firmware is already ~USB-faithful for everything that matters (input is byte-for-byte passthrough; lightbar defaults to host control; etc.). Only two defaults were flipped:
- **`polling_rate_mode` 0 → 2** (250 Hz → **1000 Hz / realtime**) — matches a wired DS5's 1 ms latency. ⚠️ Realtime also drops the report-throttle, so **this needs a 30–60 min hardware soak-test** (watch for BT drops / OLED Diag `BT31 in/s` collapse) before it merges to master. Fallback if unstable: `polling_rate_mode = 1` (500 Hz).
- **`bt_mic_enable` 1 → 0** (mic **off** by default) — the BT mic has a known 2× playback bug (#10), so it's opt-in until fixed.

Both only affect fresh flashes / Reset-to-defaults; existing saved configs keep their values.

### `audio/speaker-rate-trim` — experimental crackle fix (the active thread)
New **`SpkTrim`** setting that trims the speaker sample rate to null clock drift.

**Why:** the speaker path is 1:1 (no resampler) — it delivers samples at the **USB host's 48 kHz clock** while the DS5 consumes at **its own 48 kHz crystal**. Two independent clocks drift apart → the DS5's audio buffer slowly underruns → the periodic **crackle (#7)**. 0.6.11's "retiming" fixed the *average* rate but can't track *drift*.

**What it does:** delivers `48000 + trim` samples/s via a zero-order-hold duplicate/drop accumulator (`src/audio.cpp`, in the speaker accumulation loop). At ppm scale, a single duplicated/dropped sample is inaudible vs a 480-sample gap.

**Files changed:** `src/config.h` (field), `src/config.cpp` (clamp), `src/audio.cpp` (the trim), `src/oled.cpp` (Settings UI), `CHANGELOG.md`.

**Config field:** `speaker_rate_trim`, stored `0..200` = **−100…+100 Hz**, default **100 (= 0 Hz, an exact no-op)**. So a fresh flash sounds **identical to 0.6.11** until you sweep it — safe to flash.

**UI:** OLED **Settings** screen, item **`SpkTrim ±NHz`** (just above "Reset to defaults"), swept with the D-pad **▶ / ◀** at **1 Hz/step**. (Reset/Wipe moved to settings indices 16/17 via named constants.)

---

## Next steps on the main PC

```bash
git fetch origin
git checkout audio/speaker-rate-trim

# ensure TinyUSB is still pinned (CLAUDE.md — 0.18 that ships with SDK 2.2.0 won't compile):
( cd "$PICO_SDK_PATH/lib/tinyusb" && git checkout 0.20.0 )

cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DPICO_SDK_PATH="$PICO_SDK_PATH"
cmake --build build --target ds5-bridge        # → build/ds5-bridge-oled.uf2
# BOOTSEL the board, copy build/ds5-bridge-oled.uf2 onto the RP2350 mount
```

### The sweep test (the whole point)
1. OLED **Settings** → scroll to **`SpkTrim`** (reads `+0Hz`).
2. Play a steady tone from the host: `python3 scripts/sine_ch12.py 600` (10 min of 440 Hz on the speaker channels).
3. Nudge `SpkTrim` with the D-pad ▶/◀ and **time the interval between crackles**. A longer interval = closer to the DS5's true rate. Walk it toward the value where the crackle stops. (The crackle interval is itself a tachometer: a click every ~16 s ≈ ~600 ppm of clock error.)
4. **Decision read — leave the good value running 10–15 min:**
   - **Stays clean → static offset.** The knob is the fix; we lock in a default and ship it.
   - **Creeps back → dynamic drift.** Proof we need **adaptive resampling** (continuously measure drift and vary the trim), which is the bigger but "correct" fix. The DS5 gives no buffer back-channel, so by-ear / crackle-interval is the right instrument.

---

## Other open threads (not blocking the sweep)

- **`defaults/usb-faithful` soak-test** — validate 1000 Hz polling stability, then merge to master (or fall back to 500 Hz).
- **#10 mic 2× playback** — needs OLED **Diagnostics** `Mic dec=` (samples per `opus_decode`; `240` would confirm a half-rate stream) and `Mic in/s` (arrival rate) read with the mic enabled. Mic is off-by-default now, so it's no longer an out-of-box problem.
- **#11 constant low-level haptics** — root-caused to the **#6 adaptive-trigger fix** (`71cead4`): 0.6.11 now honors host trigger-FFB, and the dongle re-asserts `state[]` continuously via the `0x36` audio frames, so a game's idle trigger effect buzzes constantly. **Not** auto-haptics (already off). Decisive read: watch the OLED Diag **`trig`** / **`host02`** counters during the buzz — climbing = host streaming FFB (add an opt-out toggle); static = stale latch (clear FFB params when allow-bit is 0, in `src/state_mgr.cpp`).

---

## Why audio is hard (context for any new session)

The DualSense's Bluetooth audio is **not A2DP / not normal Bluetooth audio** — Sony tunnels Opus-encoded audio inside the HID controller reports (`0x31`/`0x36`) over a proprietary, undocumented protocol with no clock negotiation. A normal PC/phone paired to a DS5 over BT gets **zero** controller audio; **only the PS5** implements it (Sony built both ends + a dedicated radio). This dongle reverse-engineers that on a CYW43 chip over emulated SPI (hence the load-bearing 320 MHz overclock) with general-purpose BTstack. So the gap from PS5-quality is **fidelity, not feasibility** — the crackle and mic-2× are timing/rate bugs, not walls.

---

## Gotchas / reminders

- **Push only to `origin`** — never `upstream` / `upstream-fork`.
- **TinyUSB must be 0.20.0** or the build fails on `TUD_AUDIO_EP_SIZE`.
- Build target is `ds5-bridge`; output is `build/ds5-bridge-oled.uf2` (custom name).
- `SpkTrim = 0` is a byte-exact no-op, so flashing this branch can't regress audio.
- The `0x36` packet layout and the `state[]` re-assertion are **load-bearing** (see CLAUDE.md) — don't "simplify" the audio frame.

---

## One-paste kickoff for a fresh Claude session

> I'm on branch `audio/speaker-rate-trim`. Read `HANDOFF.md`, the latest commit message, and the `[Unreleased]` section of `CHANGELOG.md`. We added an experimental `SpkTrim` setting to chase the speaker crackle (#7) by trimming the speaker sample rate to null clock drift between the host and the DualSense. Help me build the UF2, flash it, and run the sweep test in HANDOFF.md — find the `SpkTrim` value where the crackle stops, then check whether it holds (static offset = fix) or creeps back (dynamic drift = needs adaptive resampling).
