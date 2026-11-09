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
1c. Broken frames (bright flashes in apps): with "ISO Update" enabled (bit 7 of the
   controller's power register, base+0x40), the USB controller holds a freshly loaded
   isochronous packet until the next microframe start; if the host polls first it sends a
   zero-length packet instead and the loaded packet is effectively lost. It hits the first
   packet of a frame after an idle gap: stock firmware shows it as two frames merged (stray
   `02 80` UVC header between EOI and SOI), and with packet padding as a frame missing its
   first packet (no JPEG headers -> decoders render a flash). Rate depends on host polling
   timing (much worse on host kernel 7.2.14 than 7.2.11). Confirmed with a usbmon capture:
   the camera itself sent a ZLP where the frame's first packet belonged.
   Fix: never enable ISO Update. sunxi_udc_ep_enable calls USBC_Dev_IsoUpdateEnable for ISO
   endpoints at every stream start: `bl` at 0xc01efc8c (phys 0x401efc8c, ebffe3f3) -> nop
   (e1a00000). The register can't be written via /dev/mem (MMIO not allowed), so the patch
   must be in place before the first stream after camera boot (the script does this).
   Measured (2 min each, host 7.2.14): padding only 30-46 broken frames; ISO fix + padding 0;
   ISO fix alone 0 broken, 0 merged, 0 startup junk frames.
   Superseded workarounds: padding every packet to 1024 bytes (uvc_video_encode_isoc,
   0x401dd71c e5886004 -> e5887004) hid merges but caused lost packets and 7 junk frames at
   stream start; using TxPktRdy|FIFONotEmpty for the TX-ready check (0x401f0620,
   0x401f07a4 -> USBC_Dev_IsWriteDataReady_FifoEmpty) had no effect.
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
- Host USB autosuspend kicks the camera out of webcam mode. uvcvideo enables autosuspend on
  every camera it binds (power/control=auto, 2 s delay); when no app has the camera open the
  host suspends it, and the camera's Android gadget treats a suspend as an unplug and returns
  to its menu (udev then re-selects -> loop). Fixed by the udev rule that sets
  power/control=on when uvcvideo binds 1f3a:100d/100e.
  (An adb server holding the camera's ADB interface also blocks autosuspend, which is why
  "keeping adb alive" looked like the fix at first. It was a side effect, not the cause.)
- The camera's adbd is old: `adb shell` always exits 0, so check command output, never exit codes.
- Its adbd has no `exec-out`; stage files in /dev (tmpfs) and `adb pull` them.
- Inside `while read ... < <(...)` loops, adb swallows stdin: read the loop from fd 3.
- Drops that looked like mid-stream reboots were at least partly autosuspend drops; one
  genuine reboot (00:19:42 on 2026-11-09, uptime reset) remains unexplained.
  /proc/last_kmsg does not exist on this firmware, so it needs a live `adb logcat` capture.
- Webcam-only USB mode (no ADB interface): patching sdv's "webcam,adb" string (offset 0x45ec3
  in /system/bin/sdv, ',' -> '\0') makes it select sys.usb.config=webcam (1f3a:100d).
  With the autosuspend rule it is stable (2 min idle, adb churn, stream open/close: no drops).
  Not used by default: no ADB while streaming (no live quality changes or log access).

## Limits
- USB isoc endpoint: 1x1024 B per microframe, ~8.2 MB/s. The camera streams as fast as the
  link allows: Q70 ~195 KB/frame ~40 fps; Q80 ~260-340 KB/frame ~23-31 fps.
- Frame buffer size = 1.5 x size limit.

## Files (firmware/, not tracked by git)
- firmware/firmware_backup/  full SPI flash dump (mtdblock0-7) + SHA256SUMS. Keep this.
- firmware/camera.default.orig.so  stock HAL; camera.default.1080.so  HAL with size patch at 0x280d8 (unused).
- firmware/kernel_Image  decompressed camera kernel (from mtdblock1), used for disassembly.
- firmware/librtspserver.so  camera RTSP server library (live555-based), for the Wi-Fi stream.
