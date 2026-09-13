# Finder Drawer

A standalone macOS drawer with column browsing, fast filename search, native terminal tabs, and contextual keyboard actions, originally extracted from Topside. Your folders and shells stay a shortcut away.

## Run

Requires macOS 15 or later, Xcode command-line tools with the macOS 26 SDK / Swift 6.2 or later, and Python 3. The native terminal uses SwiftTerm 1.20.0 (MIT), fetched automatically by Swift Package Manager.

```sh
python3 Scripts/build-app.py
open "dist/Finder Drawer.app"
```

The drawer opens at the top of the display under your pointer. **Control–Option–Space** toggles it globally; **Settings → General** records custom shortcuts, and offers animation, height, and auto-hide controls (auto-hide is off by default). The menu bar icon remains available while the drawer is hidden. A focused drawer supports standard macOS window controls, tiling, and full screen, and appears in the Dock while a window is open.

Browse Home, Applications, Computer, and Volumes immediately. Choose **Add Folders…** to include folders in filename search. Open the separate Settings window with **⌘,**, the toolbar gear, or either app menu. Copy the app from `dist` to Applications if you want to keep it there. The build is signed locally for development; distributing it to other Macs requires your own signing and notarization.

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
| Context actions for the selection | ⌘K |
| Search files | ⌘F or ⌘/ |
| New terminal in selected folder | ⌘T |
| Toggle sidebar | ⌃⌘S |
| Next / previous tab | ⌃Tab / ⌃⇧Tab |
| Select tab 1–9 | ⌘1–⌘9 |
| Go to folder / recent locations | o or ⇧⌘G |
| Split right / return to single pane | ⌘\ / ⇧⌘\ |
| Focus the other pane | ⌥⌘← / ⌥⌘→ |
| New file tab / close tab | ⌘N / ⌘W |
| Move between columns | ← / → or Tab / ⇧Tab |
| Parent folder | ⌘↑ |
| Open selection | ⌘Return or ⌘↓ |
| Rename selection | Return |
| Quick Look | Space or ⌘Y |
| New folder | ⇧⌘N |
| Move selection to Trash | ⌘Delete |
| Copy / cut selected files | ⌘C / ⌘X |
| Paste files | ⌘V |
| Move copied files here | ⌥⌘V |
| Duplicate selection | ⌘D |
| Undo / redo file operation | ⌘Z / ⇧⌘Z |
| Select all files in the focused column | ⌘A |
| Copy selected paths | ⌥⌘C |
| Toggle hidden files | ⌘. |
| Settings | ⌘, |
| Leave search / hide drawer | Escape |

The wider centered palette has actions (⌘K), file search (⌘F or the search icon), and location navigation (o or ⇧⌘G). Type to filter, use ↑/↓ to select, Return to open, and Escape to dismiss. Location navigation fuzzy-matches recent folders, accepts absolute, relative, and ~ paths, and uses Tab to complete a folder. Search stays above the browser in a fixed-height palette, with 40% of its width for filename results and 60% for an embedded Quick Look preview. Click or use ↑/↓ (also Control-N/P) to select, Page Up/Down to move through results, and Return or double-click to reveal a result in the browser. The selection scrolls into view as you move. Previews do not autoplay media; file contents are not indexed. Commands adapt to the selected file, folder, search result, or terminal. “Open Terminal Here in New Tab” uses a selected folder, a file’s parent, or the current folder. The header shares one native toolbar row with the traffic lights, with its location title aligned to the main content. The sidebar toggle animates and remembers its state. Settings, Actions, and Search live below a separator at the bottom of the sidebar; the old window status bar is removed. The tab-add and split buttons share a compact group immediately after the last tab and brighten on hover. The sidebar background continues behind the native window controls.

Use the Split View menu to show two file browsers, a browser and terminal, or two terminals side by side. Click either pane or use ⌥⌘←/→ to make it active; new tabs and file commands target that pane. The tab strip is shared. Selecting the tab already visible on the other side swaps the two panes. Drag the divider to resize; Single Pane keeps the active pane and leaves other tabs available. Pane assignments restore after relaunch. Settings → General provides independent width and height percentages for the next global-shortcut opening.

Terminal tabs run your login shell in a native PTY, supporting interactive programs, copy/paste, and resizing. Default terminal and selection colors follow the window’s macOS light, dark, and high-contrast appearance, including existing tabs, without restarting shells. Switching tabs or hiding the drawer keeps sessions running. Closing a terminal tab ends its shell and foreground job; quitting ends all sessions. Tabs and directories restore after relaunch, with fresh shells started only when viewed. Commands and scrollback are not restored. Shells that report their current directory with OSC 7 update the tab context; other shells retain their starting directory. Browser write restrictions do not sandbox terminal commands.

File copy/paste uses the macOS clipboard and interoperates with Finder. Cut leaves originals in place until pasted in Finder Drawer; other apps see ordinary copied files. Paste targets the selected folder, or the focused column's folder when no single folder is selected. Name collisions keep both items with a numbered name; duplicate and same-folder copy use “copy” names. Transfers run in the background and report partial failures. Right-click empty column space to paste directly into that column.

File tabs keep undo/redo history for copying, moving, duplicating, renaming, new folders, and Trash until the tab closes. Undoing a copy sends its created items to Trash; redo restores them. Restore never overwrites an existing item, and history refuses to act on files replaced since the original operation.

Text fields keep normal editing shortcuts. Quick Look and folder/settings dialogs handle their own keys.

## Develop or reuse

Open `Package.swift` in Xcode, or run:

```sh
swift test
```

If the macOS 27 beta Swift build engine stalls, use `swift test --build-system native` and `python3 Scripts/build-app.py --build-system native`.

`FinderDrawerKit` contains the browser, SQLite index, and standalone window host. `FinderDrawer` is the small executable that adds the app/menu-bar lifecycle and global shortcut. Another macOS app can add this package as a local dependency and retain a `FinderDrawerController`:

```swift
import FinderDrawerKit

// Create on the main actor and retain for the lifetime of the host app.
let drawer = try FinderDrawerController()
drawer.show()
// Call drawer.shutdown() when the host terminates.
```

The controller accepts a custom index URL, UserDefaults instance, and initial folders. Embedders should supply their own index URL and preferences domain. Browser implementation types are internal; the controller is the initial public integration point.

Finder Drawer keeps its index in `~/Library/Application Support/FinderDrawer/index.sqlite3` and preferences under `com.stevemurr.finder-drawer`. It does not import Topside’s preferences or index. The standalone app permits file operations throughout locations your account can access by default. Settings → Files & Access can restrict writes to indexed folders; those boundaries resolve symlinks. Search indexing remains limited to explicitly chosen folders in either mode. Package embedders retain restricted writes by default and can opt in with `allowsSystemWideAccess: true`.

This app is not App Sandbox enabled. macOS still enforces filesystem permissions, protected system volumes, and privacy controls. Full Disk Access cannot be granted by an entitlement or enabled automatically. Use **Settings → Files & Access → Open Full Disk Access…**, add the built app, enable it, then quit and reopen it. The adjacent **Show App in Finder** action locates the exact app bundle. Local ad-hoc rebuilds can require granting access again; use a stable Developer ID signing identity for distribution. A sandboxed host would need a security-scoped bookmark adapter.

Native Liquid Glass is used for search and toolbar controls on macOS 26 and later, including macOS 27. Older systems use vibrancy; Reduce Transparency provides solid control surfaces, and Reduce Motion disables the drawer animation. No Accessibility permission is needed to manage this app’s own window or register its global shortcut.

See [the extraction record](docs/extraction.md) for provenance, boundaries, tests, and intentional differences from the old interface.
