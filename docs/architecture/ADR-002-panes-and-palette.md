# Shared tabs, two visible panes, and one palette

## Context

File management needs two independently navigable locations, including terminals, while retaining existing tab sessions and clipboard behavior. Search and location entry should not reflow the file browser or open a separate sheet.

## Decision

Keep one tab collection and assign distinct tabs to primary and optional secondary panes. The active pane determines the selected tab and command context. Selecting the other visible tab swaps assignments, so the same terminal view is never mounted twice. Native mouse events resolve a non-interactive pane marker before being delivered to the table or terminal. Keyboard pane switching restores focus through the existing native responder locators. Save both assignments and active pane with the tab session.

Use a single centered overlay with mutually exclusive actions, indexed file search, and location modes. Native text fields retain editing shortcuts. Location mode combines recent-folder fuzzy matching, indexed folders, and filesystem path completion; exact typed paths are validated at submission independently of async suggestions. The browser remains mounted behind every palette mode. Keep the native toolbar and traffic lights, aligning its sidebar separator with the content sidebar.

## Consequences

Tabs remain available after closing the split, and dormant terminal sessions remain alive until their tab closes. The shared tab strip always changes the active pane. File histories remain owned by individual browser tabs. Plain o is reserved for location navigation only while browsing; terminals and text editors keep their normal input. History and path completion do not broaden the search index or grant filesystem permissions.
