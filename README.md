# Music-Tools
A collection of bash scripts for music files management, conversion and organisation.

## Scripts Included

This repository contains two main Bash scripts:

1.  **audio-to-opus.sh** - Convert various audio formats to Opus format with parallel processing.
2.  **organize-music.sh** - Organize audio files into folders by artist and album using metadata.

## Requirements

### For audio-to-opus.sh:
-   `opus-tools` (provides `opusenc`)
-   `ffmpeg`
-   `parallel`
-   `ffprobe` (from ffmpeg)

### For organize-music.sh:
-   `ffmpeg` (for `ffprobe`)
-   `jq`

### Installation on Android (Termux)

```bash
pkg update
pkg install opus-tools ffmpeg parallel jq

Script Details
audio-to-opus.sh
This script converts audio files to the Opus format, which offers excellent sound quality at low bitrates. It uses parallel processing for faster conversion and has a two-pass approach for maximum compatibility.
Features:
 * Converts multiple audio formats (FLAC, WAV, M4A, ALAC, AIFF, APE, WV) to Opus
 * Uses parallel processing for faster conversion
 * First tries opusenc (best quality for FLAC/WAV)
 * Falls back to ffmpeg for problematic or unsupported files
 * Backs up existing Opus files before conversion
 * Adjustable bitrate (32-512 kbps)
 * Configurable directory search depth
 * Bitrate Check: The script now checks the bitrate of input .m4a, .flac, .wav, and .alac files. If the bitrate is approximately 256 Kbps, the file is assumed to be already optimally encoded and is skipped to save processing time. 256 Kbps is a commonly used high quality bitrate for those file types, therefore those files are skipped assuming they are already optimally converted.
Usage: CLI
./audio-to-opus.sh [-b bitrate] [-d depth] [-h]

Usage: Termux
bash audio-to-opus.sh [-b bitrate] [-d depth] [-h]

Options:
 * -b bitrate: Set the encoding bitrate (32-512 kbps, default: 256)
 * -d depth: Set the directory search depth (default: 1)
 * -h: Display help message
organize-music.sh
This script analyzes audio files' metadata and organizes them into a directory structure by artist and album.
Features:
 * Extracts metadata using ffprobe
 * Creates artist/album folder structure
 * Handles missing metadata gracefully
 * Sanitizes file and folder names
 * Supports multiple audio formats (MP3, M4A, FLAC, WAV, OGG, AAC, OPUS)
 * Interactive mode to select which formats to process
 * Detailed error handling and reporting
Usage: CLI
./organize-music.sh [OPTIONS] <directory_path>

Usage: Termux
bash organize-music.sh [OPTIONS] <directory_path>

Options:
 * -h, --help: Show help message
 * -a, --all: Process all audio formats (default)
 * -i, --interactive: Interactive mode to select formats
 * -f FORMAT, --format=FORMAT: Process only specified format (can be used multiple times)
Examples:
./organize-music.sh /path/to/music                  # Process all audio formats
./organize-music.sh -f mp3 /path/to/music           # Process only MP3 files
./organize-music.sh -f flac -f opus /path/to/music  # Process FLAC and OPUS files
./organize-music.sh -i /path/to/music               # Select formats interactively

Benefits of Opus Format
The Opus format provides several advantages:
 * Excellent sound quality at low bitrates
 * Free, open standard with no licensing fees
 * Lower storage requirements than most other formats
 * Good compatibility with modern players and systems
 * Maintains quality while saving space
Workflow Example
Common workflow using both scripts:
 * Organize your music collection:
   ./organize-music.sh /path/to/music

 * Convert to space-efficient Opus format:
   cd /path/to/organized/music
/path/to/audio-to-opus.sh -b 192

Release Notes
v1.2 (Enhanced Bitrate Check)
 * Extended the bitrate check to FLAC, WAV, and ALAC files, in addition to M4A.
 * Added skipped file bitrate output.
v1.1 (Added M4A Bitrate Check)
 * Introduced bitrate checking for M4A files.
 * Skipped M4A files with bitrates close to the target bitrate (256 kbps +/- 20 kbps).
v1.0 (Initial Release)
 * Initial release of the audio-to-opus.sh script.
 * Converts various audio formats to Opus format.
License
This project is licensed under the MIT License - see the LICENSE file for details.
Contributing
Contributions are welcome! Please feel free to submit a Pull Request.
Acknowledgments
 * The Opus codec developers for creating an excellent audio format
 * The FFmpeg team for their comprehensive multimedia tools
