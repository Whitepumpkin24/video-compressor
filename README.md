# Video Compressor

A simple Windows app that compresses a video down to a **target file size in MB**.
Pick a video, type `20`, click **Compress**, and get a ~20 MB file back.

Built with a PowerShell GUI and [FFmpeg](https://ffmpeg.org). Handy for Discord, email, and messaging upload limits.

> **Vibe-coded project.** This was written with the help of AI. It works for me, but use it at your own risk. If in doubt, read the script: it is one plain-text file (`VideoCompressor.ps1`).

## Features

- Compress to an exact target size (MB) instead of guessing quality settings
- **Choose the output format:** MP4, MKV, MOV (H.264 + AAC) or WebM (VP9 + Opus)
- **Auto GPU detection**: uses NVIDIA NVENC, Intel Quick Sync, or AMD AMF if available, otherwise falls back to the CPU (x264)
- Automatic CPU fallback if a GPU encode fails
- **Force CPU** option (x264 gives the best quality per MB at small sizes)
- Optional 720p downscale (never upscales smaller videos)
- Drag and drop, progress bar, cancel button, live log
- Safe by design: encodes to a temporary `.part` file and only renames it when finished, so your original and any existing files are never damaged by a failed or cancelled run
- Warnings for targets that are too small, very low quality, or larger than the source
- Clear error messages. Details are logged to a file for troubleshooting

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (already built in)
- `ffmpeg.exe` and `ffprobe.exe` (bundled in the installer)

## Install

1. Go to the [Releases](../../releases) page.
2. Download `VideoCompressorSetup.exe`.
3. Run it, accept the agreement, and finish the wizard. You get a Start Menu entry and an optional desktop shortcut.

Windows SmartScreen may say "Windows protected your PC" because the installer is not code-signed. Click **More info**, then **Run anyway**.

## Usage

1. Open **Video Compressor**.
2. Click **Browse** (or drag a video into the window).
3. Type the **Target size (MB)** (the box starts empty, or use the **-** / **+** buttons) and pick the **Format**.
4. Click **Compress**.
5. When it finishes, the file is saved next to the original as `name_compressed.<format>` (for example `name_compressed.mkv`).

## Run from source (no installer)

1. Install FFmpeg: `winget install Gyan.FFmpeg` (or put `ffmpeg.exe` and `ffprobe.exe` next to the script).
2. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\VideoCompressor.ps1
```

## How it works

1. `ffprobe` reads the video duration.
2. Total bitrate = target size x 8 x safety margin / duration. The margin is 5% for CPU and 8% for GPU, because GPU encoders land less exactly.
3. Audio gets 128 kbps (64 kbps for very small targets). The rest goes to video.
4. **CPU:** two-pass x264 for accurate size. **GPU:** single-pass capped VBR for speed.
5. **WebM** always uses the CPU (VP9 + Opus) and is slower, because WebM cannot hold H.264. The GPU option is greyed out for it.

| Format | Codecs | Notes |
|---|---|---|
| MP4 | H.264 + AAC | Most compatible. Plays almost everywhere |
| MKV | H.264 + AAC | Flexible container, great for PC players |
| MOV | H.264 + AAC | Apple and video-editing software |
| WebM | VP9 + Opus | Web use. CPU only, slower to encode |

The result lands at or slightly under your target. Quality depends on the target: squeezing a long, high-resolution video into a few MB will look bad. Use the 720p option or a larger target.

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing happens when launching | Errors are logged to `%LOCALAPPDATA%\VideoCompressor\error.log` |
| Encoder shows `[fallback]` | The GPU encode failed (often an old driver), so it used the CPU. Update your GPU drivers |
| File is a bit smaller than the target | Expected. The safety margin keeps it from going over |
| "Enter a target size" appears | The size box starts empty on purpose. Type a number from 1 to 10000 |
| "Target is too small" | Increase the target size or use a shorter video |
| WebM is slow or Force CPU is greyed out | WebM (VP9) always runs on the CPU, so it is slower. Use MP4 or MKV for GPU speed |
| SmartScreen warning | Installer is unsigned. More info > Run anyway |

## Build the installer

Uses [Inno Setup](https://jrsoftware.org/isinfo.php) (`winget install JRSoftware.InnoSetup`).

1. Put these files in one folder: `VideoCompressor.ps1`, `VideoCompressor.iss`, `VideoCompressor.ico`, `Agreement.txt`, `LICENSE` (FFmpeg's license text), `ffmpeg.exe`, `ffprobe.exe`.
2. Open `VideoCompressor.iss` in Inno Setup and press **F9**.
3. `VideoCompressorSetup.exe` is created in the same folder.

`ffmpeg.exe` and `ffprobe.exe` are over 100 MB each, which is above GitHub's file limit, so they are not stored in this repo (see `.gitignore`). Download an FFmpeg build (for example the "essentials" build from [gyan.dev](https://www.gyan.dev/ffmpeg/builds/)) and copy the two files from its `bin` folder.

## Repo contents

| File | Purpose |
|---|---|
| `VideoCompressor.ps1` | The whole app (PowerShell + WinForms GUI) |
| `VideoCompressor.iss` | Inno Setup installer script |
| `Agreement.txt` | Agreement shown during install |
| `VideoCompressor.ico` | App icon |
| `README.md` | This file |
| `.gitignore` | Keeps the large FFmpeg binaries and built installers out of the repo |

## Disclaimer

Provided "as is" without warranty of any kind. The author is not responsible for lost or damaged files or any other problem. Keep a backup of your original videos.

## Third-party software

- [FFmpeg](https://ffmpeg.org), licensed under the GPL. The installer bundles an FFmpeg build; its license text is included as `LICENSE` in the install folder. FFmpeg source code is available from ffmpeg.org.

## License

The script and installer files in this repo are released under the MIT License.

## Author

Whitepumpkin24