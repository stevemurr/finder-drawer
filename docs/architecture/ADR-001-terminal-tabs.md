# Terminal tabs and contextual commands

## Context

The drawer now hosts both file browsing and interactive shells. A terminal must survive SwiftUI view reconstruction and tab switches, while keyboard commands must never act on a hidden browser selection.

## Decision

Use the pinned SwiftTerm 1.20.0 native AppKit terminal and local PTY implementation. A typed DrawerTab owns either a BrowserViewModel or a TerminalSession. The session retains its view and process independently of the selected tab. Start a shell lazily when its tab is mounted, pass its working directory directly to the process launcher, and stop it when the tab closes or the app quits. Save tab kinds and directories; restored terminal tabs start fresh shells when first selected.

Use a native unified compact NSToolbar to share the traffic-light row. Keep contextual actions in a separate keyboard-focused overlay. Capture the selection when opening it, filter available commands using selection cardinality and write policy, and guard browser actions against a changed selection. Cmd+K opens actions, Cmd+F searches files, and terminal text keys pass to the PTY after shared workspace shortcuts are handled.

## Consequences

SwiftTerm adds a pinned external dependency and a Metal resource bundle that the packaging script must include. Interactive shell programs, resizing, and terminal escape sequences use a maintained emulator. Session processes remain live while the drawer is hidden; closing a terminal hangs up its foreground job and shell. Shell sessions have the user's normal filesystem privileges independently of the browser's optional write restriction. Restoring a tab does not restore running commands or scrollback. Directory updates follow shell OSC 7 reports; shells that do not emit them retain the launch directory for context actions.
