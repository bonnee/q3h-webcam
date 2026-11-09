# q3h-webcam

Turns a cheap Q3H action camera (Allwinner V3 "crane-sdv" Camdroid firmware, OV4689 sensor)
into a usable **1080p30 USB webcam** on Linux, with no firmware flashing.

Stock webcam mode is MJPEG 1280×720 only, takes ~30 s to enumerate, needs a button press on
the camera every time, and occasionally glitches frames. This project patches the running
camera over ADB (RAM only; everything reverts when the camera powers off) and automates it
on every connect.

| | Stock | Patched |
|---|---|---|
| Resolution | 1280×720 | 1920×1080 |
| Frame rate | advertises 30, delivers ~50 (as fast as USB allows) | advertises 30, delivers 30–49 (link-limited, scene dependent) |
| Enumeration | ~30 s (control timeouts) | ~1 s |
| Selecting webcam mode | press buttons on camera | automatic |

It also fixes a camera-side USB bug that occasionally merges two frames into one broken pair
(with the other patches applied: 18 broken frames in 5,781 without the fix, 0 in 14,860 with it).

See [PATCHES.md](PATCHES.md) for every patch, address and the reasoning behind it.

## Requirements

`adb`, `v4l2-ctl` (v4l-utils), `python3`, `xxd`, systemd user session, udev.

## Install

```sh
systemctl --user link "$PWD/systemd/q3h-webcam.service"
sudo cp udev/99-q3h-webcam.rules /etc/udev/rules.d/ && sudo udevadm control --reload
```

Plug the camera in. Within ~5 s it should appear as a 1920×1080 webcam:

```sh
journalctl --user -u q3h-webcam -f     # what the script is doing
ls -l /dev/v4l/by-id/                  # ...Android_20080411-video-index0 is the video node
```

## Usage

- **JPEG quality**: the `75` in `systemd/q3h-webcam.service` (then `systemctl --user daemon-reload`).
  Try live with `./q3h-quality.sh <1-100>`. Higher quality = bigger frames = lower frame rate
  (USB link is ~8.2 MB/s).
- **Use the camera as a USB drive instead**: `touch disable` in this directory; remove it to
  re-enable automation.
- **Run by hand**: `./q3h-webcam.sh [quality]` while the camera shows its connect-to-PC menu.

## Notes

- The PC's adb server must keep running while streaming: if it dies, the camera treats the
  dropped ADB link as a USB disconnect and leaves webcam mode (the unit uses `KillMode=process`).
- The script restarts the adb server when it loses track of the camera, briefly dropping
  other adb connections.
- `firmware/` (not tracked) holds the full flash backup of the original camera and the vendor
  binaries used for reverse engineering. Keep the backup safe: it is the only way to restore
  the camera if its flash is ever damaged.
