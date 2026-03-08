# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SpeakBook is an iOS ePub/PDF reader with on-device text-to-speech synthesis. Users import books, read them with page/chapter navigation, and listen via streaming TTS powered by PocketTTS (Kokoro). All synthesis runs on-device using CoreML models — no cloud services.

## Build & Run

The project uses **XcodeGen** with `project.yml` to generate `SpeakBook.xcodeproj`.

```bash
# Regenerate Xcode project after changing project.yml
xcodegen generate

# Download TTS models (required before first run, ~1GB from HuggingFace)
./download_models.sh

# Build from command line
xcodebuild -project SpeakBook.xcodeproj -scheme SpeakBook -sdk iphonesimulator build
```

Open `SpeakBook.xcodeproj` in Xcode for normal development. The project depends on the **FluidAudioTTS** product from the sibling `../FluidAudio` Swift package (local path reference in project.yml).

**Requirements:** iOS 17.0+, Xcode 15.0+, FluidAudio package at `../FluidAudio`

## Architecture

### Data Flow
`LibraryView` → `ReaderView` (router) → `PDFReaderView` or `EPubReaderView` → `TTSControlBar` ↔ `TTSService`

### Key Components

**TTSService** (`Services/TTSService.swift`) — Central orchestrator wrapping `PocketTtsManager` from FluidAudioTTS. Manages the full lifecycle: model loading → text chunking → streaming synthesis → audio playback via `AVAudioEngine`. Key behaviors:
- States: `idle` → `loadingModels` → `ready` → `generating` → `playing` / `paused`
- Pre-buffers 75 audio frames (~6s) before playback starts
- Batches 5 frames per synthesis call for throughput
- Auto-unloads models after 60s idle to prevent thermal throttling
- Monitors RTFx (real-time factor) and thermal state in real-time
- Supports multiple voices and batch prefill versions (v1/v2/v3)

**EPubParser** (`Services/EPubParser.swift`) — Custom ePub extractor with built-in ZIP/DEFLATE decompression (no external zip library). Parses OPF metadata, extracts chapters from spine, converts HTML to plain text.

**Book** (`Models/Book.swift`) — SwiftData model storing title, author, file path, reading progress, and cover image data.

**TTSControlBar** (`Views/TTSControlBar.swift`) — Rich TTS control UI with voice picker, text position selector, RTFx display, and thermal indicators. Includes debug mode toggled by tapping the RTFx label.

### Patterns
- **@Observable** for reactive state (TTSService)
- **SwiftData** for library persistence
- **UIViewRepresentable** wrappers for PDFKit and WKWebView
- **Security-scoped resources** for file access from document picker
- Structured logging via `os.log` (subsystem: `com.speakbook.app`)

## TTS Models

Models live in `pocket-tts/` (gitignored). Run `./download_models.sh` to fetch them, or they download automatically on first app launch. The models are CoreML packages from the Kokoro-82M HuggingFace repo.

## Git Conventions

- Do NOT include `Co-Authored-By: Claude <noreply@anthropic.com>` in commit messages

## Deployment Constraints

- All operations must stay on-device — no cloud services
- First launch after cold start may be slow due to ANE (Apple Neural Engine) model compilation by `anecompilerservice`
