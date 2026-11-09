#!/usr/bin/env bash
# Q3H: apply 1080p webcam patches (RAM only) and switch the camera into webcam mode.
# Run while the camera is connected and showing its "connect to PC" menu (USB storage
# mode, 1f3a:1002). See PATCHES.md for what each patch does.
# Usage: q3h-webcam.sh [jpeg_quality=75]
set -euo pipefail
Q=${1:-75}
export ANDROID_SERIAL=${ANDROID_SERIAL:-20080411}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
log(){ echo "[q3h] $*"; }
if [[ -e "$(dirname "$0")/disable" ]]; then log "disabled ($(dirname "$0")/disable exists), leaving camera alone"; exit 0; fi
die(){ echo "[q3h] ERROR: $*" >&2; exit 1; }
# The camera re-enumerates its USB during boot, and the adb server sometimes misses it
# afterwards; restarting the adb server fixes that.
ensure_adb(){ local i
  for i in 1 2 3 4 5 6; do adb devices 2>/dev/null | grep -q "^$ANDROID_SERIAL[[:space:]]*device" && return 0; sleep 0.5; done
  lsusb -d 1f3a: >/dev/null 2>&1 || return 1
  log "adb server lost the camera, restarting it"
  adb kill-server >/dev/null 2>&1 || true; adb start-server >/dev/null 2>&1 || true
  timeout 20 adb wait-for-device >/dev/null 2>&1; }
sh_(){ local i out; for i in 1 2 3 4 5; do
         if out=$(timeout 20 adb shell "$@" 2>/dev/null </dev/null); then printf '%s\n' "${out//$'\r'/}"; return 0; fi
         ensure_adb || sleep 2; done; return 1; }
push_(){ local i; for i in 1 2 3 4 5; do
         timeout 20 adb push "$1" "$2" >/dev/null 2>&1 && return 0
         ensure_adb || sleep 2; done; return 1; }

# read N bytes at OFFSET from FILE on the camera -> hex
rd(){ local i; rm -f "$TMP/r.bin"; for i in 1 2 3 4 5; do
        sh_ "dd if=$1 bs=1 skip=$2 count=$3 2>/dev/null > /dev/q3h_r.bin" >/dev/null &&
        timeout 20 adb pull /dev/q3h_r.bin "$TMP/r.bin" >/dev/null 2>&1 && break
        ensure_adb || sleep 2; done
      [[ -s $TMP/r.bin ]] || die "read failed"; xxd -p "$TMP/r.bin" | tr -d '\n'; }
# patch FILE at OFFSET: expect hex ORIG (or already NEW), write hex NEW, verify
patch(){ local f=$1 off=$2 orig=$3 new=$4 name=$5 n=$(( ${#4} / 2 )) cur
  cur=$(rd "$f" "$off" "$n")
  if [[ $cur == "$new" ]]; then log "$name: already applied"; return; fi
  [[ $cur == "$orig" ]] || die "$name: unexpected bytes $cur (want $orig) - firmware differs, not touching it"
  echo "$new" | xxd -r -p > "$TMP/p.bin"
  push_ "$TMP/p.bin" /dev/q3h_p.bin || die "$name: push failed"
  sh_ "dd if=/dev/q3h_p.bin of=$f bs=1 seek=$off count=$n 2>/dev/null" >/dev/null
  [[ $(rd "$f" "$off" "$n") == "$new" ]] || die "$name: verify failed"
  log "$name: ok"; }

# --- patch table: name|file|offset|orig_hex|new_hex (quality handled separately) ---
FD=$(python3 -I -c "import struct;print(struct.pack('<HHIII',1920,1080,995328000,995328000,4147200).hex())")
QHEX=$(printf '%02x21' "$Q")
patches(){ cat <<P
kernel frame descriptor 1080p|/dev/mem|$((0x403811b7))|0005d00200005e1a00005e1a00201c00|$FD
kernel: drop Auto-Exposure control (slow enumeration)|/dev/mem|$((0x40381181))|02|00
kernel: drop Brightness control (slow enumeration)|/dev/mem|$((0x4038118c))|01|00
kernel: no ISO Update on video endpoint (fixes broken frames)|/dev/mem|$((0x401efc8c))|f3e3ffeb|0000a0e1
HAL size table 1920x1080|$M|$((B+0x34828))|00050000d0020000|8007000038040000
HAL JPEG size limit 400KB|$M|$((B+0x28130))|400d0300|801a0600
HAL JPEG quality $Q|$M|$((B+0x276fc))|5021|$QHEX
P
}
menu_shown(){ [[ $(sh_ 'logcat -d -s MainWindow.cpp:V' | grep -c 'connect2Pc dialog' || true) -gt 0 ]]; }
find_hal(){ PID=$(sh_ ps | awk '/mediaserver/{print $2}')
  BASE=$([[ -n $PID ]] && sh_ "grep -m1 'r-xp.*camera.default.so' /proc/$PID/maps" | cut -d- -f1 || true)
  [[ -n $PID && -n $BASE ]] || return 1; B=$((0x$BASE)); M=/proc/$PID/mem; }
webcam_dev(){ v4l2-ctl --list-devices 2>/dev/null | grep -A1 'UVC Camera' | sed -n 2p | tr -d '\t' || true; }

log "waiting for camera (ADB)..."
for i in 1 2 3 4 5 6 7 8 9 10; do ensure_adb && break; sleep 3; done; ensure_adb || die "camera not found over ADB"

for i in $(seq 120); do find_hal && menu_shown && break; sleep 0.5; done
find_hal || die "camera HAL not loaded"
menu_shown || die "connect-to-PC menu not showing; not pressing any keys"


# fast path: read every patch location (and key files) in one round-trip
cmd=""; while IFS='|' read -r -u 3 name f off orig new; do
  cmd+="dd if=$f bs=1 skip=$off count=$(( ${#new} / 2 )) 2>/dev/null; "; done 3< <(patches)
sh_ "{ $cmd } > /dev/q3h_s.bin" >/dev/null 2>&1 || true
rm -f "$TMP/s.bin"; timeout 20 adb pull /dev/q3h_s.bin "$TMP/s.bin" >/dev/null 2>&1 || true
STATE=$(xxd -p "$TMP/s.bin" 2>/dev/null | tr -d '\n'); WANT=""
while IFS='|' read -r -u 3 name f off orig new; do WANT+=$new; done 3< <(patches)

if [[ $STATE == "$WANT" ]]; then
  log "patches already in place (pid $PID)"
else
  log "applying patches (mediaserver pid $PID, HAL base 0x$BASE)"
  while IFS='|' read -r -u 3 name f off orig new; do
    if [[ $name == HAL\ JPEG\ quality* ]]; then
      orig=$(rd "$f" "$off" 2); [[ $orig =~ ^..21$ ]] || die "JPEG quality instruction: unexpected bytes $orig"
    fi
    patch "$f" "$off" "$orig" "$new" "$name"
  done 3< <(patches)
fi

# --- select webcam in the menu: DOWN, OK (retry if the camera bounces back to the menu) ---
# key files live in the camera's RAM (/dev); always push them (old adbd gives no exit codes)
ev(){ python3 -I -c "
import struct,sys
c=int(sys.argv[1]); s=b''
for v in (1,0): s+=struct.pack('<IIHHi',0,0,1,c,v)+struct.pack('<IIHHi',0,0,0,0,0)
sys.stdout.buffer.write(s)" "$1"; }
ev 115 > "$TMP/down.bin"; ev 139 > "$TMP/ok.bin"
push_ "$TMP/down.bin" /dev/q3h_down.bin && push_ "$TMP/ok.bin" /dev/q3h_ok.bin || die "push failed"
[[ $(sh_ 'ls /dev/q3h_down.bin /dev/q3h_ok.bin' | grep -c q3h_) == 2 ]] || die "key files missing on camera"
# sdv blanks the screen after 30 s idle; the first key press then only wakes it (and is
# swallowed). Latest PowerManager screenOn/screenOff log line tells us the state.
screen_state(){ sh_ 'logcat -d -s PowerManager:V' | grep -oE 'screen(On|Off)\(\)' | tail -1; }
for attempt in 1 2 3; do
  if [[ $(screen_state) == 'screenOff()' ]]; then
    log "camera screen is off, waking it first"
    timeout 10 adb shell 'cat /dev/q3h_down.bin > /dev/input/event0' </dev/null >/dev/null 2>&1 || true
    for i in $(seq 12); do [[ $(screen_state) == 'screenOn()' ]] && break; sleep 0.25; done
    [[ $(screen_state) == 'screenOn()' ]] || die "screen did not wake up; not pressing further keys"
    sleep 0.3
  fi
  sh_ 'logcat -c' >/dev/null   # a retry/next run must see a fresh menu event before pressing keys
  # one shell call: DOWN, pause, OK. After OK the camera switches USB mode and ADB goes away.
  timeout 10 adb shell 'cat /dev/q3h_down.bin > /dev/input/event0; sleep 0.5; cat /dev/q3h_ok.bin > /dev/input/event0' >/dev/null 2>&1 || true
  log "webcam selected (attempt $attempt), waiting for /dev/video0..."
  t0=$SECONDS
  for i in $(seq 60); do
    dev=$(webcam_dev)
    [[ -n $dev ]] && { log "ready: $dev ($((SECONDS-t0))s) - $(v4l2-ctl -d "$dev" --list-formats-ext | grep -m1 Size | xargs)"; exit 0; }
    sleep 0.25
  done
  # no webcam: if the camera is back at its menu, try again
  ensure_adb || die "camera disappeared"
  for i in $(seq 20); do menu_shown && break; sleep 0.5; done
  menu_shown || die "webcam did not appear and the menu is not showing"
  log "camera bounced back to the menu, retrying"; sleep 1
done
die "webcam did not come up after 3 attempts"
