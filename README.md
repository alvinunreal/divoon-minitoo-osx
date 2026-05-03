# Divoom MiniToo macOS Daemon

Tools for sending images, GIFs, and short videos to a **Divoom MiniToo** over Bluetooth Classic RFCOMM from macOS.

The core of this repo is a Swift daemon that keeps the Divoom app channel open, plus a small macOS menu-bar app and Python media conversion tooling.

> `omo-slim/` contains local working media/assets and is not the main project API. The reusable project is the daemon, menu-bar app, CLI, and protocol notes.

## What this does

- Opens the Divoom MiniToo app protocol over Bluetooth RFCOMM channel `1`.
- Avoids repeated macOS Bluetooth audio reconnect/disconnect by keeping one daemon connection open.
- Converts PNG/JPEG/GIF/MP4/video into the Divoom animation payload format.
- Sends jobs through a localhost daemon at `127.0.0.1:40583`.
- Provides a copyable macOS `.app` that starts the daemon from the menu bar.

## Device assumptions

The current defaults are for one tested device:

```text
Bluetooth name: Divoom MiniToo-Audio
Bluetooth MAC:  B1:21:81:B1:F0:84
RFCOMM channel: 1
Daemon port:    40583
```

If your device has a different Bluetooth address, update the address in the Swift tools or pass it manually to `tools/divoom-daemon`.

## Requirements

- macOS
- Xcode Command Line Tools / Swift compiler
- Homebrew `blueutil` for audio-profile disconnect/reconnect convenience:

```bash
brew install blueutil
```

For development CLI use:

- Python virtualenv with `Pillow`, `zstandard`, and `pyserial`
- `ffmpeg` for GIF/video input

The packaged app bundles the repo `.venv`, so normal app usage does not need the active shell Python environment.

## Build the macOS app

```bash
tools/build-divoom-app.sh
```

This builds:

```text
build/Divoom MiniToo.app
```

Install it:

```bash
cp -R "build/Divoom MiniToo.app" /Applications/
open "/Applications/Divoom MiniToo.app"
```

On launch, the app:

1. Disconnects the Divoom macOS audio profile once using `blueutil`.
2. Starts the Swift RFCOMM daemon.
3. Keeps the daemon available from the menu bar.

Logs and generated packet artifacts are written under:

```text
~/Library/Application Support/DivoomMiniToo/
```

## Menu-bar app

The menu-bar title indicates daemon state:

```text
◇ Divoom = daemon stopped
◆ Divoom = daemon running
```

Useful actions:

- **Send Image/GIF/Video…** — choose a media file and send it.
- **Disconnect Audio + Start Daemon** — use when macOS audio owns the Bluetooth connection.
- **Restart Daemon** — stop, disconnect audio, and reopen RFCOMM.
- **Open Menu Log / Open Daemon Log** — inspect failures.

## CLI usage

Start the daemon manually:

```bash
blueutil --disconnect B1:21:81:B1:F0:84 || true
tools/divoom-daemon B1:21:81:B1:F0:84 1 40583
```

Send media through the daemon:

```bash
.venv/bin/python tools/divoom_send.py path/to/image.png
.venv/bin/python tools/divoom_send.py path/to/animation.gif
.venv/bin/python tools/divoom_send.py path/to/video.mp4
```

Recommended compact video/GIF profile:

```bash
.venv/bin/python tools/divoom_send.py path/to/animation.gif \
  --size 128 \
  --fps 8 \
  --speed 125 \
  --max-frames 24 \
  --posterize-bits 4
```

Build packet files without sending:

```bash
.venv/bin/python tools/divoom_send.py path/to/media.mp4 --build-only
```

Ask the daemon to parse but not send:

```bash
.venv/bin/python tools/divoom_send.py path/to/media.mp4 --daemon-dry-run
```

## Integration API

For most integrations, call `divoom_send.py` as a subprocess. It is the media-level API:

```text
image/GIF/video -> Divoom packets -> daemon -> Bluetooth
```

Example:

```bash
"/Applications/Divoom MiniToo.app/Contents/Resources/.venv/bin/python" \
  "/Applications/Divoom MiniToo.app/Contents/Resources/tools/divoom_send.py" \
  "/absolute/path/to/file.gif" \
  --size 128 --fps 8 --speed 125 --max-frames 24 --posterize-bits 4
```

The daemon itself is packet-level. It listens on:

```text
127.0.0.1:40583
```

It accepts JSON pointing to a prebuilt length-prefixed packet file:

```json
{
  "packets": "/absolute/path/to/file-packets-lenpref.bin",
  "delay": 0.012,
  "dryRun": false
}
```

Python example:

```python
import json
import socket

req = {
    "packets": "/absolute/path/to/file-packets-lenpref.bin",
    "delay": 0.012,
    "dryRun": False,
}

with socket.create_connection(("127.0.0.1", 40583), timeout=10) as s:
    s.sendall(json.dumps(req).encode() + b"\n")
    s.shutdown(socket.SHUT_WR)
    print(s.recv(65536).decode())
```

Typical success response:

```json
{"ok":true,"message":"sent","packets":457,"bytes":122949,"sawRequest":true,"sawAck":true}
```

## Protocol notes

Full reverse-engineering notes are in [`PROTOCOL.md`](PROTOCOL.md).

High-level transport:

```text
01 <declared_len_le16> <cmd> <body...> <checksum_le16> 02
```

Animation/photo command:

```text
0x8b = SPP_APP_NEW_GIF_CMD2020
```

Media payloads are RGB888 frames compressed with Zstandard and wrapped in Divoom `0x8b` start/chunk packets.

Important finding:

```text
zstd window_log=17
```

This matches Android captures and avoids black/glitched output seen with larger zstd windows.

## Repository layout

```text
PROTOCOL.md                  Reverse-engineering and validation notes
tools/DivoomDaemon.swift     Swift RFCOMM daemon
tools/DivoomMenuBar.swift    macOS menu-bar controller
tools/divoom_send.py         Preferred media send CLI
tools/send_divoom_image.py   Image/GIF/video conversion + packet builder
tools/divoom_clock.py        Custom face selection helper
tools/build-divoom-app.sh    Builds packaged macOS app
omo-slim/                    Local test/media assets; not core project API
```

## Troubleshooting

If daemon start fails with an RFCOMM error, disconnect the audio profile once:

```bash
blueutil --disconnect B1:21:81:B1:F0:84
```

Then restart the daemon or reopen the app.

If a send reports `sent but final ACK not observed`, the device may still have updated successfully. This is usually an ACK-observation issue, not necessarily a failed transfer.

If video/GIF transfer is too slow, reduce frames before reducing pixels:

```bash
--size 128 --fps 6 --speed 167 --max-frames 18 --posterize-bits 4
```

Keep `--zstd-window-log 17` unless deliberately testing protocol behavior.
