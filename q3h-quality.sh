#!/bin/sh
# Set the Q3H webcam JPEG quality live (RAM only, lost on power-off).
# Usage: q3h-quality.sh <quality 1-100>
# Patches the "movs r1,#80" at offset 0x276fc in camera.default.so inside the
# running mediaserver. Takes effect on the next frame.
set -e
Q=${1:?usage: $0 <quality 1-100>}
[ "$Q" -ge 1 ] && [ "$Q" -le 100 ] || { echo "quality must be 1-100"; exit 1; }
export ANDROID_SERIAL=${ANDROID_SERIAL:-20080411}
PID=$(adb shell ps | tr -d '\r' | awk '/mediaserver/{print $2}')
BASE=$(adb shell "grep -m1 'r-xp.*camera.default.so' /proc/$PID/maps" | tr -d '\r' | cut -d- -f1)
[ -n "$PID" ] && [ -n "$BASE" ] || { echo "camera not found"; exit 1; }
ADDR=$((0x$BASE + 0x276fc))
TMP=$(mktemp)
printf "$(printf '\\%03o\\041' "$Q")" > "$TMP"     # Thumb: movs r1,#Q  -> bytes [Q, 0x21]
adb push "$TMP" /dev/q.bin >/dev/null
adb shell "dd if=/dev/q.bin of=/proc/$PID/mem bs=1 seek=$ADDR count=2 2>/dev/null"
rm -f "$TMP"
echo "JPEG quality set to $Q (pid $PID, addr $(printf %x $ADDR))"
