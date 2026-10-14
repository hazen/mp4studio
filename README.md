# MP4Studio

A native Apple silicon Mac app for converting, remuxing, tagging, splitting and joining MP4 and MKV video. It's a SwiftUI front end for standard open-source command-line tools, installed as arm64 builds from Homebrew.

MP4Studio was inspired by [MP4tools](https://emmgunn.com/wp/mp4tools-home/) by EmmGunn. MP4tools is no longer maintained, and its last version (3.7, 2019) is Intel-only, so it stops working when Rosetta is retired. MP4Studio rebuilds its workflow natively. It shares no code with MP4tools.

## Requirements

- A Mac with Apple silicon, running macOS 14 Sonoma or later
- [Homebrew](https://brew.sh) and these tools:

```sh
brew install ffmpeg mkvtoolnix gpac atomicparsley
```

| Tool | Used for |
|---|---|
| ffmpeg / ffprobe / ffplay | Converting, remuxing, reading track info, MP4 splitting, preview |
| mkvmerge / mkvextract (mkvtoolnix) | MKV track editing, splitting, joining and extraction |
| MP4Box (gpac) | MP4/M4V track editing and joining |
| AtomicParsley | iTunes-style tags, cast/crew, rating, artwork |

MP4Studio finds the tools in `/opt/homebrew/bin` automatically. You can point it at other copies in **Settings ▸ Tools**, which also confirms that each tool is a native Apple silicon build.

## Installation

### From a DMG

1. Install the Homebrew tools above.
2. Open `MP4Studio-<version>.dmg` and drag **MP4Studio** onto **Applications**.
3. The app is ad-hoc signed, not notarized, so the first launch on a new Mac is blocked. Open it once, then go to **System Settings ▸ Privacy & Security** and click **Open Anyway**. Or, in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/MP4Studio.app
   ```

### From source

Building needs Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/hazen/mp4studio.git
cd mp4studio
scripts/build-app.sh --install   # builds build/MP4Studio.app and copies it to /Applications
scripts/make-dmg.sh              # or: builds build/MP4Studio-<version>.dmg
```

The scripts build against the Command Line Tools' macOS 26.5 SDK when it's present. The macOS 27 SDK needs Xcode's SwiftUI macro plugin, which only works once the Xcode license has been accepted (`sudo xcodebuild -license`).

To use your own app icon, put it at `Resources/AppIcon.icns`. That path is gitignored. Without it, the build generates a default icon.

## Features

- **Convert**: open several files at once (or drop them on the Dock icon), choose tracks, set language, title, default and forced flags, add external .srt or audio files, and queue.
  - Video: pass-through, x264 (CRF or 2-pass), x265, or Apple VideoToolbox H.264/HEVC. Device targets cap the resolution and set the H.264 profile and level.
  - Audio: AAC stereo, with an optional stereo track added before surround. Surround can be AC3, E-AC3 or pass-through. DTS and TrueHD become AC3 in MP4.
  - Subtitles: soft (tx3g in MP4) or burned in.
  - Also: segment extraction, square pixels for anamorphic video, chapters, fast start, and iTunes metadata written after conversion.
- **Presets**: conversion settings plus track-selection rules (all, first, by language, none; with fallback), and an option to burn in forced subtitles.
- **Edit Tracks**: remove or add tracks and fix language, name and default/forced flags without re-encoding. Uses MP4Box for MP4/M4V and mkvmerge for MKV. The original file is never changed.
- **Extract Tracks**: mkvextract for MKV, ffmpeg stream copy for everything else.
- **Split & Join**: split by size, by length, or extract a segment; join files in any order.
- **Metadata**: edit tags on MP4/M4V files in place: TV show fields, descriptions, cast/directors/writers/producers, rating and artwork. "Copy Show Info to All" helps tag a season at once.
- **Queue**: one job at a time, with progress, time remaining, pause/resume, stop and retry. Each job's log is in `~/Library/Logs/MP4Studio`, and you can copy a job's exact commands from its context menu. The Mac stays awake while jobs run.
- **Watch Folder**: new files are converted with a preset once they finish copying.

## Tests

The tests run every command builder against generated sample media, using the real tools:

```sh
scripts/test.sh
```

## Notes

- Homebrew's ffmpeg is built without libass, so text subtitles (SRT/ASS) can't be burned in. Image subtitles (PGS/VobSub) can. For text burn-in, install an ffmpeg with libass (e.g. `brew tap homebrew-ffmpeg/ffmpeg && brew install homebrew-ffmpeg/ffmpeg/ffmpeg`) and select it in **Settings ▸ Tools**.
- MP4 splitting uses ffmpeg's segmenter. On files with sparse subtitle tracks, MP4Box's `-split`/`-splits` stop after the first part but still exit successfully.
- Online metadata search (TMDB/TVDB) isn't included.

## License

MIT. See [LICENSE](LICENSE). MP4tools and its artwork belong to EmmGunn and are not part of this project.
