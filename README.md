# Finder Drawer

A standalone macOS file drawer with column browsing and fast filename search, extracted from Topside. Your folders and search stay a shortcut away, without the terminal or agent workspace.

## Run

Requires macOS 15 or later, Xcode command-line tools with Swift 6 or later, and Python 3. There are no third-party package dependencies.

```sh
python3 Scripts/build-app.py
open "dist/Finder Drawer.app"
```

Choose **Add Folders…** on first launch. The folder icon in the menu bar and **Control–Option–Space** show or hide the drawer. Copy the app from `dist` to Applications if you want to keep it there. The build is signed locally for development; distributing it to other Macs requires your own signing and notarization.

## What it does

- Native column browsing with keyboard navigation, independent tabs, folder shortcuts, and live directory updates.
- Rename, new folder, trash, multi-selection, drag-and-drop, Open With, copy paths, and reveal in Finder.
- Indexed file and folder **name** search, including filename substrings and short queries. Return on a search result reveals it in the browser; Open launches its default application.
- Search-result previews and Space for Quick Look; sorting, hidden-file visibility, and file-size preferences.

Search includes only the folders you choose, omits hidden files/package descendants, and respects nested `.gitignore` rules plus cache exclusions. It returns up to 200 matches. File contents are not indexed. The index refreshes at launch, when showing the drawer, after its file operations, or with **Refresh Search Index**. Open columns watch for external changes; the search index does not continuously watch every folder recursively.

## Keyboard

| Action | Shortcut |
| --- | --- |
| Show / hide drawer globally | ⌃⌥Space |
| Search | ⌘K or ⌘/ |
| Go to folder | ⇧⌘G |
| New / close tab | ⌘T / ⌘W |
| Move between columns | ← / → or Tab / ⇧Tab |
| Parent folder | ⌘↑ |
| Open selection | ⌘Return or ⌘↓ |
| Rename selection | Return |
| Quick Look | Space or ⌘Y |
| New folder | ⇧⌘N |
| Move selection to Trash | ⌘Delete |
| Copy selected paths | ⌥⌘C |
| Toggle hidden files | ⌘. |
| Settings | ⌘, |
| Leave search / hide drawer | Escape |

Text fields keep normal editing shortcuts. Quick Look and folder/settings dialogs handle their own keys.

## Develop or reuse

Open `Package.swift` in Xcode, or run:

```sh
swift test
```

`FinderDrawerKit` contains the browser, SQLite index, and standalone window host. `FinderDrawer` is the small executable that adds the app/menu-bar lifecycle and global shortcut. Another macOS app can add this package as a local dependency and retain a `FinderDrawerController`:

```swift
import FinderDrawerKit

// Create on the main actor and retain for the lifetime of the host app.
let drawer = try FinderDrawerController()
drawer.show()
// Call drawer.shutdown() when the host terminates.
```

The controller accepts a custom index URL, UserDefaults instance, and initial folders. Embedders should supply their own index URL and preferences domain. Browser implementation types are internal; the controller is the initial public integration point.

Finder Drawer keeps its index in `~/Library/Application Support/FinderDrawer/index.sqlite3` and preferences under `com.stevemurr.finder-drawer`. It does not import Topside’s preferences or index. File writes remain limited to configured roots, with symlink-aware boundary checks. This app is not App Sandbox enabled; a sandboxed host would need a security-scoped bookmark adapter.

See [the extraction record](docs/extraction.md) for provenance, boundaries, tests, and intentional differences from the old interface.
