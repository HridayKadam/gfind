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

## The notch

GFind also turns the MacBook notch into a panel of small tools. Hover the notch to open it (or press ⌥⌘N). On a Mac or display without a notch, GFind draws one at the top of the screen.

When closed, the notch can show the clock, today's revenue, your scratchpad or a scrolling message. Running timers and new sales always appear there. Each tool can be switched off in **Settings › Notch**, and there are three themes: Minimal, Playful and Neon.

| Tool | What it does |
| --- | --- |
| Home | Clock, your next event, the song playing in GFind, quick launcher |
| Revenue | Today's Stripe takings from a restricted read-only key (stored in the keychain), with a banner for every sale |
| Scratchpad / Notes | One always-there text box that can be pinned to the notch, plus a notes list with an editor |
| Shelf | Drag files onto the notch to park them, then drag them out into any app |
| Calendar | Seven-day agenda, reminders you can tick off, and adding a reminder |
| Timers | Pomodoro that remembers your cycles, 5/10/25-minute countdowns, a stopwatch with laps, a hydration nudge |
| Stats | CPU, memory and disk rings, network speed, battery level, health and cycle count |
| Screen Time | Which app was in front while you were active, today and over seven days (recorded on this Mac) |
| Weather | Current conditions, the next hours and seven days, from Open-Meteo (no key needed) |
| Clipboard | Searchable history of text, links, images and files, with the source app. Skips copies that password managers mark as private |
| Files | Convert or shrink an image to JPEG, PNG, HEIC or PDF, with quality and max-size controls |
| Links | Search Google, DuckDuckGo, Perplexity, YouTube or GitHub, plus your saved sites |
| Emoji | Searchable, categorised picker. A click copies the emoji |
| Sounds | Eight layered ambient sounds (rain, waves, wind, fire, noises, hum), generated on the device, with a fade-out timer |
| Message | Your text across the notch in a dot-matrix style: scroll, bounce, wave, sparkle, pulse or rainbow, plus a flash |
| Claude | Claude Code tokens, messages, tool calls and sessions today, your streak, a heatmap and usage per project, read from `~/.claude/projects` |
| Units | Length, mass, temperature, volume, speed, data, time and area conversions |

Not included: web-analytics integrations (DataFast, Google Analytics), and payment providers other than Stripe.

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
| `Notch/Notch.swift` | The notch window, hover behaviour, collapsed "live activity", themes |
| `Notch/Stores.swift` | Shelf, clipboard, notes, timers, message, screen time, keychain, Stripe |
| `Notch/Services.swift` | System stats, sound synthesis, weather, calendar, Claude usage, emoji, image conversion |
| `Notch/Tools.swift` | The tool views |

## Not yet included

- Shortcuts / Siri actions. App Intents need an Xcode build to register their metadata.
- Automatic updates (Sparkle) and signing / notarisation with a Developer ID.
