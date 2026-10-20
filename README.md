# GFind

A native SwiftUI file browser for macOS, built as a friendlier companion to Finder. It shows your files as big thumbnails sorted onto shelves by kind, lets you search in plain English, reads the text inside screenshots, and helps you clear out what you don't need.

Everything runs on your Mac. There's no account, no cloud and nothing is uploaded.

## Features

- **Shelves**: Images, Videos, Music, Documents, Archives and Apps, each with a count and total size, plus Recents, Screenshots and Large Files smart folders.
- **Natural-language search** (⌘F): "pdfs from last week over 5 mb", "zips bigger than 1gb older than 6 months", "screenshots with wifi password", "pdfs from gmail". Each query is shown as filter chips you can remove one at a time. Searches can be saved to the sidebar.
- **Text in images**: Apple's Vision framework reads screenshots, recent photos and PDFs on your Mac. Search that text, or copy it from one or several files (⇧⌘C, or the Copy Text button that appears when you hover an image).
- **Downloaded From** (⇧⌘J): downloads grouped by where they came from (Gmail, Google Drive, ChatGPT, Slack, WhatsApp, GitHub, X, browser extensions, any website), using macOS's `kMDItemWhereFroms` record.
- **Duplicates** (⇧⌘D): identical files found by SHA-256 (size first, then a partial hash, then a full hash) and look-alike photos found with Vision feature prints. GFind picks a copy to keep; click another to keep that one instead.
- **Clean Up** (⇧⌘K): cards for forgotten downloads, old installers, old screenshots, big old videos and unused apps, each with a review page and Trash Selected / Trash All.
- **Quick Search** (⇧⌘Space from any app): a Spotlight-style panel. ↩ opens the file, ⌘↩ shows it in GFind, ⌥↩ shows it in Finder. The shortcut can be changed in Settings.
- **Menu bar**: your 10 newest downloads with thumbnails, ready to drag into another app.
- **Two looks**: Playful (pastel) or Minimal (greyscale). Switch with ⌃⌘T. Both follow light and dark mode.
- Quick Look (Space), grid and list views (⌘1 / ⌘2), card size (⌘+ / ⌘−), an Inspector (⌘I) showing dimensions, duration, camera and source, a built-in music player, pinned folders, right-click actions, and drag and drop.
- Optional automatic clean-up rules (off by default): send old installers to the Trash, and file Desktop screenshots into a folder per month.

**Safety**: GFind never deletes anything outright. Every removal goes to the Trash. Files stored only in iCloud are skipped, so nothing gets downloaded without you asking.

## Build

Requires macOS 14+ and Xcode or the Swift 5.9+ command-line tools.

```bash
./build.sh            # builds dist/GFind.app and dist/GFind.dmg
./build.sh install    # also installs to /Applications and launches it
```

For development, `swift build && swift run` works too. Run as a bundled app for folder-permission prompts and the icon.

On first launch macOS will ask for access to Desktop, Documents and Downloads. GFind needs this to show and search those folders.

## Layout

| File | Purpose |
| --- | --- |
| `Scanner.swift` | Walks the folders, reads metadata, the "where from" record and Spotlight's last-used date |
| `Library.swift` | Central store: the index, duplicates, Clean Up cards, saved searches, pinned folders, Trash |
| `Query.swift` | Turns plain English into filters (kind, date, size, source, words) |
| `TextIndex.swift` | Vision OCR plus PDF and text extraction, cached in `~/Library/Application Support/GFind` |
| `Duplicates.swift` | SHA-256 and feature-print duplicate finder, and the Clean Up rules |
| `QuickSearch.swift` | Global search panel and menu bar window |
| `MainView.swift`, `ToolViews.swift`, `Components.swift` | The UI |
| `AppState.swift` | Shared UI state, thumbnails, music player, global hotkey |

## Not yet included

- Shortcuts / Siri actions. App Intents need an Xcode build to register their metadata.
- Automatic updates (Sparkle) and signing / notarisation with a Developer ID.
