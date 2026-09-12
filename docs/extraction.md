# Extraction record

## Context

Finder Drawer was extracted from `stevemurr/topside` at commit `e44156ffdb7f6726720ebc8a1c264044e1b7abbf` on September 12, 2026. Topside’s original browser-first interface existed at `2ecd463`; `079bf10` removed it during the Flight Deck cutover on August 14. The browser behavior and search index remained in production.

## Decision

Keep the current behavior and build a small browser-first host around it. The package is a native macOS Swift package using AppKit, SwiftUI, Observation, SQLite3, QuickLookUI, and UniformTypeIdentifiers. The executable additionally uses Carbon for its global hotkey. Swift 5 language mode preserves the source project’s concurrency assumptions; the package manifest requires Swift 6 tools.

Retained from Topside:

- `Sources/Browser`: column state, AppKit tables, row editing, layout, directory listing/watchers, file operations, and command definitions.
- `Sources/Search`: index database/service/crawler, root persistence and write boundaries, nested ignore scopes and exclusions.
- The ignore parser from `Sources/WorkPane/Terminal/TerminalShellIgnoreRules.swift`, relocated to `Search/GitignoreRules.swift` with no terminal dependency.
- Search results/state, Quick Look controller, native search field, thin scrollers, and URL persistence helpers.

Adaptations:

- `TopsideResult` → `FileSearchResult`, `AppViewModel` → `FileSearchModel`, neutral scroller names, and a small native `DrawerTheme`.
- `BrowserPreferences` now stores only hidden-file visibility, sizes, and sorting.
- Remove Talkie/agent and terminal commands; restore Command-T for browser tabs.
- Host callbacks now connect to `DrawerWorkspace` and `FinderDrawerController`. No imports or paths reference the original repository or its sibling packages.
- Fresh preferences and index identity; no copied user state or external dependencies.

The new interface follows the original column-browser/search model; it is not a byte-for-byte restoration of its visor, command palette, sidebar, or tab chrome. It keeps native file operations and Quick Look, and intentionally omits the terminal, agent, document editor, MCP server, and project-content search.

## Validation and consequences

The initial isolated core passed all 96 carried-over tests before adding the host. These cover directory sorting/watchers, file mutation boundaries, multi-selection, rename/focus behavior, column layout, search query/filter/rebuild behavior, ignored paths, folder persistence, and native search-field editing.

One source-text assertion about Flight Deck’s view composition was omitted because that host is not part of this package. The host-command cardinality test now uses Open With instead of the removed Talkie action. Additional tests cover the search-to-browser handoff, independent tabs, root revocation, result selection, closing the final tab, restoring the selected tab, leaving search for a new tab, and idempotent shutdown.

The library has a narrow initial public API (`FinderDrawerController`). Internal browser and search types can be evolved without immediately committing to a broad package API. UI behavior remains macOS-specific. Search reads filenames rather than file bodies, and index refresh remains batched rather than a continuously watched recursive index.

Topside’s original source is untouched. This repository carries extracted source rather than the parent’s entire Git history; the commit IDs above identify the original history.

Final verification in the new repository: `swift test` passed **104 tests with zero failures**; `python3 Scripts/build-app.py` produced the release app; `codesign --verify --strict` passed. The executable links only system frameworks/libraries. A fixture-only UI smoke check verified indexed search, the inline preview, Return revealing the exact file in its column, and Quick Look. The release app was also launched from this repository and its first-run folder selection state was checked.
