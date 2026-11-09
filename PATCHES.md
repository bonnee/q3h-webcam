# Q3H webcam 1080p patches (RAM-only, lost on power-off)

Camera: Allwinner V3 "crane-sdv" Camdroid 4.2.2 (2016-03), OV4689 sensor, RTL8189ES Wi-Fi.
Root ADB is available when the camera is in USB storage mode (serial 20080411).
Hardware watchdog (8 s) is fed by `sdv`: never stop `sdv` for long, or the camera resets.

## Patches (applied in this order, then select webcam on the camera)

1. Kernel UVC frame descriptor `uvc_frame_mjpg_720p` (virt 0xc03811b2, phys 0x403811b2),
   write 16 bytes at phys 0x403811b7 via /dev/mem:
   `<HHIII` = 1920, 1080, 995328000, 995328000, 4147200
   (orig: 1280, 720, 442368000, 442368000, 1843200)
   Must be applied BEFORE webcam mode is selected (descriptors are copied at bind).
1b. Fast enumeration: the camera never answers UVC control requests, so the host waits
   5 s per query (~30 s total). Clear the advertised controls so the host doesn't ask:
   - Camera Terminal bmControls[0] phys 0x40381181: 02 -> 00 (Auto-Exposure Mode)
   - Processing Unit bmControls[0] phys 0x4038118c: 01 -> 00 (Brightness)
   Result: /dev/video0 appears ~1 s after selecting webcam.
1c. Glitched frames: the camera's USB device controller sometimes merges a frame's short
   final isoc packet with the next frame's first packet (seen as a stray `02 80` UVC header
   between one JPEG's EOI and the next SOI). Fix: never send short packets.
   In uvc_video_encode_isoc (0xc01dd67c), `req->length = req_size - len` ->
   `req->length = req_size`: kernel text phys 0x401dd71c, `str r6,[r8,#4]` (e5886004) ->
   `str r7,[r8,#4]` (e5887004). Padding lands after the JPEG EOI and is ignored by decoders.
   Measured over 2-3 min captures, all other patches applied: without this fix 18 broken
   frames / 5781; with it 0 / 14,860. Pure stock (720p, no patches) not measured yet.
   Side effect: the HAL queues its 7 buffers empty at stream start; they now arrive as
   7 junk 1022-byte frames (~150 ms) that decoders reject.
   Tried and rejected: padding only non-empty packets (cmp r6,#0 / moveq r7,#2) gave
   15 broken frames / 6018 (first packet of a frame lost), cause not understood.

## Selecting webcam mode without touching the camera
Menu (storage / webcam / charge) is driven by sunxi-keyboard = /dev/input/event0.
Inject struct input_event (`<IIHHi`, EV_KEY=1 then EV_SYN) by writing to /dev/input/event0:
DOWN (115), then OK (139). Keys: MODE 116, UP 114, DOWN 115, OK 139, POWER 28, MENU 102.
The menu appears on connect/boot and again after an app closes the webcam stream; sdv logs
"connect2Pc dialog" (tag MainWindow.cpp) when it opens.

## Automation
- q3h-webcam.sh [quality]: verifies original bytes, applies everything, presses DOWN+OK.
  Refuses to press keys unless a fresh "connect2Pc dialog" log line is present.
  Touch `disable` in the repo root to make it do nothing (e.g. to use USB storage mode).
- systemd/q3h-webcam.service (linked into ~/.config/systemd/user) runs it; udev/99-q3h-webcam.rules
  (install to /etc/udev/rules.d/) starts the service whenever the camera appears as 1f3a:1002.

2. camera.default.so (in mediaserver, via /proc/<pid>/mem; base = r-xp mapping start):
   - base+0x34828: UVC size table `<II` 1280,720 -> 1920,1080
   - base+0x28130: uvc_init literal, JPEG size limit 200000 -> 400000
   - base+0x276fc: JPEG quality `movs r1,#80` (bytes 50 21); 70 = 46 21. Use q3h-quality.sh.
   - live UVC state struct (+0x70 = size limit) only exists while webcam mode is active;
     find it by scanning mediaserver anon memory for w=1920@+0x54, h=1080@+0x58.
     Not needed if base+0x28130 is patched before webcam mode is selected.

## Gotchas learned the hard way
- The host adb server must outlive the script. If it dies while the camera is in webcam mode,
  the camera sees its ADB link drop, treats it as a USB disconnect and leaves webcam mode
  (udev then re-selects -> endless loop). Hence KillMode=process in the systemd unit.
- The camera's adbd is old: `adb shell` always exits 0, so check command output, never exit codes.
- Its adbd has no `exec-out`; stage files in /dev (tmpfs) and `adb pull` them.
- Inside `while read ... < <(...)` loops, adb swallows stdin: read the loop from fd 3.
- The camera has also rebooted once mid-stream (00:19:42 on 2026-11-09), cause unknown;
  /proc/last_kmsg does not exist on this firmware, so it needs a live `adb logcat` capture.

## Limits
- USB isoc endpoint: 1x1024 B per microframe, ~8.2 MB/s. The camera streams as fast as the
  link allows: Q70 ~195 KB/frame ~40 fps; Q80 ~260-340 KB/frame ~23-31 fps.
- Frame buffer size = 1.5 x size limit.

## Files (firmware/, not tracked by git)
- firmware/firmware_backup/  full SPI flash dump (mtdblock0-7) + SHA256SUMS. Keep this.
- firmware/camera.default.orig.so  stock HAL; camera.default.1080.so  HAL with size patch at 0x280d8 (unused).
- firmware/kernel_Image  decompressed camera kernel (from mtdblock1), used for disassembly.
- firmware/librtspserver.so  camera RTSP server library (live555-based), for the Wi-Fi stream.
