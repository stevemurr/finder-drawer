# ADR-004: Selection-driven native file preview canvas

## Context

The browser should use the approved rounded-pane design and show a rich trailing preview only for one selected file. Folder navigation, batch selection, native rename, and split tabs must retain their existing behavior. Media and large documents must not block directory navigation.

## Decision

Keep the resident NSTableView column stack and its existing selection model. BrowserPaneView places a separately framed preview after it when `previewEntry` identifies exactly one file. Clearing selection or navigating to a folder removes the preview; no folder contact sheet is shown. Narrow split panes allow horizontal access to the browser and preview without replacing their tables.

A cancellable background inspection produces immutable metadata and preview payloads. Text reads stop at 256 KB, image decoding creates a bounded 2,000-pixel thumbnail, and waveforms sample at most two channels in 180 bounded windows. A stale selection never publishes its payload. Metadata comes from ImageIO, AVFoundation, or PDFKit, with unavailable fields omitted.

Use native AVPlayer playback, PDFKit paging/zoom, a selectable read-only NSTextView for text/code, and SwiftUI rendering for common Markdown blocks. Unknown formats fall back to Quick Look. No web renderer executes file contents. Each mounted media preview owns its player and removes time/status observation when dismissed.

## Consequences

File actions and keyboard selection continue to use AppKit tables; preview insertion does not recreate the working table. Back/Forward stores bounded folder URL history, without keeping listings or players alive. The preview's Space shortcut is scoped to the active browser's selected media.

Waveforms are sampled summaries, not full-resolution editing waveforms. Image zoom enlarges the bounded preview. Code highlighting is a lightweight lexer rather than a language server. Markdown supports headings, paragraphs, lists, quotes, fenced code and inline formatting, with source view for other constructs. Very large text is explicitly marked as a partial preview.
