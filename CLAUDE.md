# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Raspberry Pi Pico 2 W (RP2350) firmware that bridges a Sony DualSense (DS5) controller over Bluetooth Classic to a USB host. Presents itself to the host as a USB HID + UAC1 audio composite device. This repo is `MarcelineVPQ/DS5Dongle-OLED-Edition`, a personal fork of upstream `awalol/DS5Dongle` that adds an optional Waveshare Pico-OLED-1.3 status display (10 screens) and a 4-slot persistent multi-controller pairing layer.

`README.md` is authoritative for user-facing capability; `CHANGELOG.md` tracks what shipped per release. Read both before proposing changes — much of the design is non-obvious from the code alone (audit history, BT pairing-posture rationale, overclock requirement).

## Build

This is firmware — there are no tests. Verification is hardware-in-the-loop (see "Hardware-in-the-loop workflow" below).

The build is **non-trivial to set up** because it requires a specific TinyUSB version:

```bash
# Pico SDK 2.2.0 must be installed; export PICO_SDK_PATH.
# CRITICAL: TinyUSB must be pinned to 0.20.0. The 0.18.0 that ships with
# Pico SDK 2.2.0 lacks the 4-arg form of TUD_AUDIO_EP_SIZE used by
# src/tusb_config.h — compile errors with no clear pointer to the cause.
cd "$PICO_SDK_PATH/lib/tinyusb"
git fetch --tags && git checkout 0.20.0

# Build
cd /path/to/DS5Dongle
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DPICO_SDK_PATH="$PICO_SDK_PATH"
cmake --build build --target ds5-bridge
# Produces build/ds5-bridge-oled.uf2  (output name set in CMakeLists.txt, not the default)
```

Common build flags (set via `-D` on the cmake invocation):

- `ENABLE_SERIAL=ON` — route printf to USB CDC for debugging. Default OFF (production).
- `ENABLE_VERBOSE=ON` — chatty BT/HID logging. Default OFF.
- `ENABLE_BATT_LED=OFF` — disable the low-battery LED blink. Default ON.
- `PICO_W_BUILD=ON` — build for the original Pico W (drops audio, lower clock). Default targets Pico 2 W.

CI runs four build variants in `.github/workflows/build.yml` (standard / debug / no-batt-led / Pico W). When changing build flags or CMake, update the workflow accordingly.

## Hardware-in-the-loop workflow

There are no software tests. To verify a change:

1. Build → produces `build/ds5-bridge-oled.uf2`.
2. Put Pico into bootloader: hold BOOTSEL, plug USB. It mounts as `/run/media/$USER/RP2350` (Linux) or `RPI-RP2` (others).
3. Copy the UF2 to the mount: `cp build/ds5-bridge-oled.uf2 /run/media/$USER/RP2350/` — Pico auto-reboots into the new firmware.
4. Pair a DualSense: hold Create + PS on the controller until the lightbar pulses; the dongle inquiry picks it up.
5. Verify enumeration host-side: `lsusb | grep 054c:0ce6` should show `Sony Corp. DualSense wireless controller (PS5)`.

The development cadence is **one feature per UF2 + checkpoint with the user before moving on** — the user has hardware in front of them, regressions are caught the same minute, and large multi-feature commits make root-causing hard.

## Architecture

**Two cores, asymmetric workload:**

- **Core 0** runs everything: `main()` infinite loop in `src/main.cpp` drives `cyw43_arch_poll()` → BTstack, `tud_task()` → TinyUSB, `audio_loop()` (USB → BT haptic path), `interrupt_loop()` (BT → USB HID path), and `oled_loop()`.
- **Core 1** runs only `core1_entry()` in `src/audio.cpp` — the Opus speaker encoder. The two cores communicate via Pico SDK `queue_t` (`audio_fifo`) and a critical section (`opus_cs`).

**Two parallel data paths through the firmware:**

1. **HID** (DS5 input → host, host output → DS5): `src/bt.cpp` registers `on_bt_data()` → `src/main.cpp:on_bt_data()` → updates `interrupt_in_data[63]` → `tud_hid_report()`. Output reports come the other way through `tud_hid_set_report_cb`.
2. **Audio** (host USB audio → DS5 speaker + haptics): `src/audio.cpp:audio_loop()` reads 4-channel USB UAC1, splits ch1/2 (speaker → Opus encode on core1 → BT 0x32 report) and ch3/4 (haptic → resample 48k→3k → BT 0x32 report).

**BT layer:** Uses Pico SDK's bundled BTstack (no separate clone). `src/bt.cpp` is the only file that touches HCI/L2CAP. PSMs are `PSM_HID_CONTROL` and `PSM_HID_INTERRUPT`. Link keys live in BTstack's TLV NVM with `NVM_NUM_LINK_KEYS=4` (configured in `src/btstack_config.h`).

**OLED add-on is optional and self-contained:** All 10 screens, the SH1107 SPI driver, the 5×7 font, the icon table, and the input handling live in `src/oled.cpp` (~30 KB). The only outward dependencies are read-only accessors (`bt_is_connected`, `bt_get_addr`, `audio_peak_*`, `bt_get_signal_strength`, the new slot accessors) and the global `interrupt_in_data[63]` (read-only for input visualization). When no OLED is wired, the SPI writes go nowhere — no init check needed.

**Multi-slot pairing (Phase G):** Storage is two-tier:

- **Link keys** stay in BTstack's TLV NVM (4 slots, unchanged from upstream).
- **bd_addrs + occupancy** in a custom flash sector owned by `src/slots.cpp` — sector below the config sector (`PICO_FLASH_SIZE_BYTES - 2*FLASH_SECTOR_SIZE`).

Slot routing is enforced in `src/bt.cpp`'s `HCI_EVENT_INQUIRY_RESULT` handler: skip devices owned by other slots, accept only the current slot's bd_addr if occupied, auto-assign on first `L2CAP_EVENT_CHANNEL_OPENED` for HID_CONTROL when the current slot is empty. Switching slots flows: `bt_set_slot()` → persist new index → `bt_disconnect()` → `HCI_EVENT_DISCONNECTION_COMPLETE` → restart inquiry under new filter.

**Flash layout** (top of flash, growing downward):

| Sector | Owner | Contents |
|---|---|---|
| `PICO_FLASH_SIZE_BYTES - 1*FLASH_SECTOR_SIZE` | `src/config.cpp` | `Config{magic, version, crc32, size, body}` — 9 user-tunable fields incl. `current_slot` |
| `PICO_FLASH_SIZE_BYTES - 2*FLASH_SECTOR_SIZE` | `src/slots.cpp` | `SlotsData{magic, addrs[4][6], occupied[4]}` |

`config_save()` and `save_slots_to_flash()` both use `save_and_disable_interrupts()` + `flash_range_erase` + `flash_range_program`. `PICO_FLASH_ASSUME_CORE1_SAFE=1` is set in CMakeLists.txt — flash writes happen while core1 may be running, but core1's hot path (Opus encode) does not access XIP during the brief erase/program window.

## Critical gotchas

These are non-obvious from the code; they cost time when forgotten.

- **Overclock 320 MHz @ 1.20 V is load-bearing.** Dropping voltage to 1.10 V *or* clock to stock breaks the CYW43 PIO SPI bus (BT chip becomes unreachable). Tested. Don't "optimize" `src/main.cpp:main()`'s `vreg_set_voltage(VREG_VOLTAGE_1_20)` + `set_sys_clock_khz(SYS_CLOCK_KHZ, true)` block.
- **Render functions are `__attribute__((noinline))` on purpose.** With aggressive inlining the compiler folds all 10 `render_screen_*` into `oled_loop()`, which then exceeds Thumb's 4 KB literal-pool reach and the linker emits `dangerous relocation: unsupported relocation`. If you remove the noinline attributes or merge two render functions into a single huge one, the build will fail at link time. The symbol size grows over time as screens get richer — the lambda inside `render_screen_settings` was already hoisted to a noinline `format_settings_item()` for the same reason.
- **`config_default()` is implemented in this fork**, not upstream. Upstream declares it in `config.h:30` but never defines it. The implementation in `src/config.cpp` fills the body with `0xFF` and re-runs `config_valid()` (matches a freshly-erased flash sector). Don't assume any header declaration is implemented just because it compiles — check the .cpp.
- **Screen indices are symbolic.** `kScreenStatus`, `kScreenSlots`, `kScreenLightbar`, … are defined in a single block near the top of `src/oled.cpp`. `oled_loop()`'s switch and `handle_buttons()`' KEY1 contextual checks (Trigger preset cycle, Lightbar mode cycle) refer to them by name. Never hard-code integers — reorder = one-block edit.
- **OLED `kPin*` pinout is hardcoded** to the Waveshare Pico-OLED-1.3 standard (`kPinMOSI=11`, `kPinCLK=10`, `kPinCS=9`, `kPinDC=8`, `kPinRST=12`, `kPinKey0=15`, `kPinKey1=17`). SPI1 instance. Conflicts with anything else on those pins. Pico's BT chip uses internal SPI to CYW43 (different bus), and USB / UART pins (GP0/GP1) are also free — no conflicts in default config.
- **DS5 PS+Mute hold-2-seconds → `watchdog_reboot(0,0,0)`** is the headless soft-reboot path (see `src/main.cpp:interrupt_loop()`). It checks `interrupt_in_data[9]` bits 0+2. If you change input report layout, this combo breaks silently.
- **Inactivity-disconnect uses `packet[3..12]`** in the L2CAP interrupt data path (`src/bt.cpp:l2cap_packet_handler`). It's looking at sticks and DPad/buttons to decide "idle." Don't touch those bytes' layout without updating the heuristic.
- **The 0x36 BT audio packet layout is load-bearing — speaker + HD haptic actuators silently die without the SetStateData sub-report.** Upstream commit `3a31bd7` (May 2026, "refactor: add SetStateData and audio send priority") moved the `0x10` SetStateData block out of every audio frame and into a one-time L2CAP-open setup. The DualSense hardware requires that sub-report (specifically the `0x7f 0x7f` Headphones + Speaker volume bytes) at `pkt[11..75]` of every `0x36` frame, or the actuators stop producing output even though USB and BT byte counts look fine. Our fork keeps `state_data[63]` in `src/audio.cpp` and re-asserts it on every frame; the pre-3a31bd7 packet layout is: state_data at `pkt[11..75]`, haptic at `pkt[76..141]`, speaker format at `pkt[142]`, opus payload at `pkt[144..343]`. If you rebase onto an upstream that has the refactor and don't preserve this restoration, speaker + HD haptics silently break. The `scripts/test_speaker.sh` helper + the `USB aud / BT 0x32` counters on the OLED Diagnostics screen are the regression tripwire — if bytes are flowing but you hear nothing, look at packet contents not flow. Upstream PR #93 is tracking a proper unified fix; ours is the pre-refactor revert applied just to `audio.cpp`. Same fix was shipped independently by `loteran/DS5Dongle` (commit `c7a8d3c`).

## Git / branch model

- **`master` (origin)** = `MarcelineVPQ/DS5Dongle-OLED-Edition` (this fork's primary branding, what users download).
- **`upstream` / `upstream-real`** = `awalol/DS5Dongle` (read-only mirror for `git fetch upstream && git rebase` cycles).
- **`upstream-fork`** = `MarcelineVPQ/DS5Dongle-upstream-fork` (a separate cleanroom fork retained from earlier PR contributions; not the active development branch).

Commits in this repo include a `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer for AI-assisted work.

## Where features live

When asked to modify behavior, the *first* file to read is usually one of:

- New BT pairing / connection state behavior → `src/bt.cpp` (HCI + L2CAP event handlers).
- New OLED screen or change to existing one → `src/oled.cpp`.
- New persistent config field → `src/config.h` (struct), `src/config.cpp:config_valid()` (defaults + clamping), `src/oled.cpp:format_settings_item()` (UI), `src/oled.cpp:settings_adjust()` (D-pad ▶◀ behavior). Update `CHANGELOG.md`.
- USB descriptor or interface change → `src/usb_descriptors.cpp` + `src/tusb_config.h`.
- Audio / haptic path → `src/audio.cpp`. **Don't** add stack arrays sized smaller than the resampler / Opus expects (this is the C1 bug that caused the long-standing "audio stuttering" issue — fix landed in upstream `5b04cbd`, but the lesson stands).

## Don't do these

- **Don't disable the watchdog** without explicit user authorization. `watchdog_enable(1000, true)` in `src/main.cpp:main()` is the safety net for hangs.
- **Don't add fallbacks for missing OLED** beyond what `oled.cpp` already does (no init checks, SPI writes harmlessly to nothing) — the firmware must boot identically with or without the display.
- **Don't write a new flash sector backend** without updating the `static_assert(SECTOR_OFFSET % FLASH_SECTOR_SIZE == 0)` pattern from `slots.cpp` and confirming no overlap with `config.cpp`'s sector.
- **Don't push to `upstream` or `upstream-fork`** by accident — only `origin/master` is the personal fork's deployment target.
