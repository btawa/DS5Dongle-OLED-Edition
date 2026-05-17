#!/usr/bin/env bash
# test_speaker.sh — play audio through the DualSense speaker via the Pico bridge.
#
# The Pico exposes itself as a 4-channel UAC1 audio device (VID:PID 054c:0ce6).
# Channels 0+1 route to the DS5 speaker; channels 2+3 drive the HD haptic motors.
# Stereo audio fills 0+1 and leaves 2+3 silent (no haptic noise).
#
# Usage:
#   scripts/test_speaker.sh                 # 3-second 440 Hz sine
#   scripts/test_speaker.sh --tone 880 5    # 5-second 880 Hz sine
#   scripts/test_speaker.sh path/to/audio   # play a file (anything paplay accepts)

set -euo pipefail

find_sink() {
    pactl list short sinks 2>/dev/null \
        | grep -iE 'dualsense|sony|054c' \
        | awk '{print $2}' \
        | head -n1
}

play_tone() {
    local freq="$1" dur="$2"
    echo "Playing ${dur}s sine at ${freq} Hz on $SINK ..."
    ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i "sine=frequency=${freq}:duration=${dur}" \
        -ac 2 -ar 48000 -f wav - \
        | paplay --device="$SINK"
}

play_file() {
    local path="$1"
    [[ -f "$path" ]] || { echo "Error: file not found: $path" >&2; exit 1; }
    echo "Playing $path on $SINK ..."
    paplay --device="$SINK" "$path"
}

if [[ "${1-}" == -h || "${1-}" == --help ]]; then
    sed -n '2,11p' "$0"
    exit 0
fi

SINK="$(find_sink)"
if [[ -z "$SINK" ]]; then
    echo "Error: no DualSense audio sink found." >&2
    echo "  Check the DS5 is paired:  lsusb | grep 054c:0ce6" >&2
    echo "  Check the sink shows up:  pactl list short sinks" >&2
    exit 1
fi

case "${1-}" in
    --tone)
        play_tone "${2:-440}" "${3:-3}"
        ;;
    "")
        play_tone 440 3
        ;;
    *)
        play_file "$1"
        ;;
esac

echo
echo "If you heard nothing on the DS5 speaker, sanity checks:"
echo "  - DS5 is paired and connected? (lsusb | grep 054c:0ce6)"
echo "  - Sink not muted?  pactl get-sink-mute $SINK"
echo "  - DS5 hardware speaker switch / mute LED not on?"
echo "  - OLED Settings -> Spk Vol not set to -100 dB (silent floor)?"
