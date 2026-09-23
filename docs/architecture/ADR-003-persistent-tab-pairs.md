# Persistent tab pairs

## Context

A split must remain a reusable pair when the user switches to other locations. Assigning arbitrary tabs to two global panes loses that relationship.

## Decision

Keep the session collection, with an ordered group collection above it. Each group owns one session or two distinct sessions plus its focused member. Selecting a group mounts its member(s); selecting a member focuses that side without swapping the pair. New tabs create singles, splitting a single adds a partner, and unpairing replaces the group with adjacent singles. Each session belongs to exactly one group. Tab-strip closing and Cmd-W close a whole group.

Save all groups, their focused members, and the selected group alongside the existing session records. During restoration, map original saved indices to successfully restored sessions before rebuilding groups. A missing partner leaves a single; legacy visible-pane preferences migrate to one pair. Retain the legacy keys for older builds. Suppress writes while restoring so intermediate tab creation cannot overwrite saved group state.

## Consequences

Pairs survive switching, unpairing preserves live shells and browser state, and keyboard tab selection follows the visible strip. Dormant groups keep their sessions alive. Splitting an existing pair is unavailable; unpair first or create a new single. Browser file histories remain attached to sessions. This supersedes ADR-002’s global pane-assignment model.
