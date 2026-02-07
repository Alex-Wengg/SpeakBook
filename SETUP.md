# audioReader - iOS ePub/PDF Reader with TTS

## Project Setup

To build this app, create an Xcode project:

1. **Open Xcode** → File → New → Project
2. Select **iOS → App**
3. Configure:
   - Product Name: `audioReader`
   - Interface: **SwiftUI**
   - Storage: **SwiftData**
   - Include Tests: Optional
4. **Delete** the auto-generated `ContentView.swift` and `audioReaderApp.swift`
5. **Drag all files** from this folder into the Xcode project
6. **Set Info.plist**: In project settings, set "Info.plist File" to `Info.plist`
7. **Add FluidAudio dependency** (see below)

## Adding FluidAudioTTS Dependency

Since audioReader uses FluidAudioTTS for text-to-speech:

### Option 1: Local Package (if FluidAudio is in parent directory)
1. In Xcode: File → Add Package Dependencies
2. Click "Add Local..."
3. Navigate to `../FluidAudio` and select the package
4. Select **FluidAudioTTS** product

### Option 2: Workspace Setup
1. Create a new Xcode Workspace
2. Add both the audioReader project and FluidAudio package
3. In audioReader target → Frameworks → Add FluidAudioTTS

## Project Structure

```
audioReader/
├── audioReaderApp.swift      # App entry point with SwiftData container
├── Info.plist                # App configuration with document types
├── Models/
│   └── Book.swift            # SwiftData model for library
├── Views/
│   ├── LibraryView.swift     # Main library grid with import
│   ├── ReaderView.swift      # Container that routes to PDF/ePub readers
│   ├── PDFReaderView.swift   # PDFKit-based PDF reader
│   ├── EPubReaderView.swift  # WKWebView-based ePub reader
│   └── TTSControlBar.swift   # Text-to-speech playback controls
├── Services/
│   ├── EPubParser.swift      # ePub file parser with ZIP extraction
│   ├── PDFMetadataExtractor.swift  # PDF cover/metadata extraction
│   └── TTSService.swift      # FluidAudioTTS wrapper for playback
└── Utilities/
    └── FileTypes.swift       # UTType extension for .epub
```

## Features

- Import PDF and ePub files from Files app
- Library view with book covers
- PDF reading with page navigation
- ePub reading with chapter navigation
- Automatic reading progress save/restore
- Delete books from library
- **Text-to-Speech** (via FluidAudioTTS/PocketTTS)
  - Natural streaming synthesis
  - Play/pause/stop controls
  - Voice selection (alba, heart, bella)
  - On-device synthesis (no cloud)

## Requirements

- iOS 17.0+
- Xcode 15.0+
- FluidAudio package (for TTS)

## TTS Model Download

On first use, PocketTTS models will be downloaded automatically from HuggingFace:
- Flow-matching language model (~4 CoreML models)
- Voice conditioning data
- Tokenizer assets

Models are cached in the app's cache directory and reused across launches.

## Testing

1. Build and run on Simulator or device
2. Tap + to import a PDF or ePub from Files
3. Tap a book to open the reader
4. Navigate pages/chapters
5. Tap the speaker icon to show TTS controls
6. Tap play to hear the current page/chapter read aloud
7. Close and reopen - progress should be restored
