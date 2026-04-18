# Mythic Dungeon Tools — "Next Pull" Highlight Feature

**Specification Document v0.2**
**Target addon:** [MythicDungeonToolsReloaded](https://github.com/Nnoggie/MythicDungeonTools)
**Status:** In Development

---

## 1. Summary

This document specifies a new feature for the Mythic Dungeon Tools (MDT) addon that dynamically highlights the next enemy pack the tank should engage, based on the currently loaded dungeon route and the group's live progress through that route. The goal is to reduce cognitive load on the tank, eliminate ambiguity about which pack is "next," and reduce route deviations caused by misreading the planned pull on a small minimap or static MDT window.

## 2. Problem Statement

MDT currently displays a complete dungeon route as a series of numbered, color-coded pulls overlaid on the dungeon map. Once the key is in progress, the tank must:

1. Remember the planned pull number they are currently on.
2. Visually parse a static map containing 15–25 colored pull groups.
3. Cross-reference their in-world position against the map.
4. Identify which specific mob group is the next pull (often distinguishing between two visually adjacent packs of the same color).

This is error-prone, particularly under combat pressure or when running an unfamiliar route shared by another player. Mistakes commonly result in over-pulling, missing a planned pack, or pulling out of sequence — any of which can fail a key. The addon already has all the data needed to assist (route, pull order, enemy positions, live combat state via the WoW API); it simply does not surface it as a directed cue.

## 3. Goals

- Visually distinguish the **next pull** in the route from all other pulls inside the MDT window.
- Surface the same information **outside** the MDT window so the tank does not have to keep it open mid-pull.
- Update progress **automatically** as enemies in a pull die, with manual override.
- Remain unobtrusive for non-tank players (opt-out / role-aware).

## 4. Non-Goals

- Pathing assistance (telling the tank *how* to walk to the next pack). This is a future enhancement (§10).
- Replacing existing MDT route-planning UI.
- Server-side communication or telemetry beyond MDT's existing party-sync channel.
- Suggesting routes or modifying them automatically.

## 5. User Stories

- **As a tank**, I want a clear visual cue showing which pack to pull next so I do not have to mentally track the pull number.
- **As a tank**, I want this cue to update automatically as I complete pulls so I am not clicking through the addon mid-combat.
- **As a tank loading someone else's route**, I want to follow it confidently without having studied it for hours.
- **As a DPS or healer**, I want to optionally see the same cue so I can pre-position or pre-cast.
- **As a route author**, I want my routes to "just work" with this feature without re-authoring.

## 6. Functional Requirements

### 6.1 Pull State Tracking
The addon must track each pull in the active route as one of four states:

| State | Definition |
|---|---|
| `completed` | All non-trivial mobs in the pull are dead. |
| `active` | At least one mob in the pull has been killed by the party, and the pull is not yet completed. Multiple pulls may be active simultaneously when chain-pulling. |
| `next` | The lowest-numbered pull whose state is neither `completed` nor `active`. |
| `upcoming` | All other pulls. |

At any moment exactly one pull is in the `next` state (unless the route is finished).

### 6.2 In-Addon Highlighting
Within the MDT window, the `next` pull's enemy blips must be rendered with a distinguishing visual treatment that is unmistakable at a glance, including:

- A pulsing outer glow on each mob in the pull (additive-blended circle texture with alpha animation).
- A bold, enlarged, green-tinted pull number badge with a pulsing scale animation.
- Optional dimming of `completed` and `upcoming` pulls (configurable 0–100%, default off) to reduce visual noise.

The treatment must remain legible when overlaid on the existing pull color, including for users with the colorblind-friendly palette enabled.

### 6.3 Out-of-Addon Indicators
A new lightweight HUD element (the "Next Pull Beacon") must be available, independent of the main MDT window:

- A small movable frame (~200 × 65 px at default scale) showing: pull number badge, enemy portrait strip (3–4 creature portraits using `SetPortraitTextureFromCreatureDisplayID`), mob count, and enemy forces %.
- A smaller "upcoming preview" row below the main content, showing the pull after "next" (pull number, mob count, forces %) so tanks who chain-pull can plan ahead.
- A progress bar that fills as mobs die when the pull is active.
- Manual override buttons (complete, skip, revert) visible on hover.
- Both elements update reactively whenever pull state changes.

### 6.4 Automatic Progression
The current pull must advance from `next` → `active` → `completed` automatically, driven by:

- `COMBAT_LOG_EVENT_UNFILTERED` events for `UNIT_DIED` / `PARTY_KILL` filtered by the route's known NPC IDs.
- `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED` for combat boundary detection.
- MDT's existing enemy-forces tracker for sanity-checking completion.

### 6.5 Mob Identification and Disambiguation

MDT routes store enemies as `{ enemyIndex, cloneIndex }` tuples mapped to NPC IDs. The combat log gives NPC IDs from GUIDs (`select(6, strsplit("-", guid))`).

Since WoW GUIDs cannot be mapped back to specific MDT clone indices, kill tracking is performed by **NPC-type count per pull**, not by specific clone. A pull containing 3 clones of NPC ID 12345 is considered complete when 3 instances of NPC 12345 have been killed and attributed to that pull.

When the same NPC ID appears in multiple pulls, kills are attributed to pulls in priority order: `active` > `next` > lowest-index `upcoming`.

### 6.6 Manual Override
The tank must be able to manually:

- Mark a pull as completed (e.g., a stealthed assassin reset the encounter, but the planned skip is fine).
- Mark a pull as not-yet-done (e.g., a mob in the pull bugged out alive somewhere).
- Skip directly to a specific pull (e.g., the group decided to deviate).

These actions should be one click each from the Beacon and from the in-addon pull list.

### 6.7 Party Sync
Pull state must be synchronized across all party members who have the addon installed, using MDT's existing addon comms channel (extends the Live Session system with a new `MDTLivePullSt` prefix). The tank is the authoritative source by default; this is configurable.

### 6.8 Role Awareness
The feature must default to:

- **Tank spec:** all indicators on (in-addon highlight + Beacon).
- **Other specs:** in-addon highlight on, Beacon off.

Every default must be overridable per-character.

### 6.9 Sublevel Handling
Pull state tracking is per-preset, not per-sublevel. When the user changes the displayed sublevel in the MDT window, the next-pull glow only appears on blips visible on the current sublevel. The state machine itself does not depend on sublevels — enemy identification uses `(enemyIdx, cloneIdx)` which implicitly encodes sublevel.

## 7. Technical Design

### 7.1 Data Model
A new ephemeral `MDT.nextPullState` object tracks the live run state. It contains a `pullStates` array (indexed 1..N matching preset pulls), a reverse-lookup table `npcIdToPulls` mapping NPC IDs to pull indices for O(1) CLEU lookups, and a GUID dedup set. This object is **not** persisted to the saved route file — it lives only for the duration of the run.

### 7.2 Event Pipeline

A new `Modules/NextPull.lua` module subscribes to the events listed in §6.4. On each relevant event it:

1. Updates `pullStates` for any affected pulls.
2. Recomputes which pull is `next`.
3. Calls `MDT:NextPull_UpdateAll()` to notify all visual consumers.
4. Sends a sync message if the local player is the authoritative source.

Consumers (in-addon renderer, Beacon) are called directly from `NextPull_UpdateAll()`, consistent with the existing codebase's direct-call pattern (no CallbackHandler).

### 7.3 Performance
The hot path is `COMBAT_LOG_EVENT_UNFILTERED`, which fires extremely frequently. The handler must early-exit on non-death subevents and on GUIDs not belonging to any route mob. Per-event work in the common case must be O(1) (hash lookup into `npcIdToPulls`), not O(pulls).

### 7.4 Persistence
User-configurable visual settings live in MDT's existing `db.global.nextPull` table. No schema migration is needed for existing saved routes.

## 8. UI / UX

### 8.1 Visual Hierarchy
At any time the tank should be able to identify the next pull within ~250 ms of looking at either the MDT window or the Beacon. The hierarchy is: pulse + glow > color > number. Color alone is insufficient because pulls reuse colors and because the player may be colorblind.

### 8.2 Beacon Layout
The Beacon is a single horizontal frame, roughly 200 × 65 pixels at default scale, anchored top-center of the screen by default. It contains, left to right: pull number badge, enemy portrait strip (3–4 creature portraits), mob count, enemy-forces percentage. Below: a smaller upcoming-pull preview row. Right-click opens settings; left-click-drag moves it; shift-click locks/unlocks.

### 8.3 Pull Button Sidebar
Each pull button in the sidebar gains a state icon (12 × 12 px) showing:
- `completed`: green checkmark
- `active`: pulsing combat indicator
- `next`: bright arrow indicator
- `upcoming`: no icon (default)

### 8.4 Edge Cases
- **Route finished:** Beacon shows "Route complete — [forces % over/under]" and stops pulsing.
- **Off-route combat:** if the party engages a mob not in any pull, Beacon shows a subtle "off-route" indicator but does not advance progress.
- **Wipe:** the active pull stays active with its mob-kill count preserved. The user can manually complete it via the Beacon or pull button context menu.
- **Boss pulls:** treated as normal pulls. Phase-based bosses (e.g., a pull with an adds phase) complete only when the boss dies, not when the adds die.
- **Chain pulling:** multiple pulls may be in `active` state simultaneously. The Beacon shows the lowest-index active pull. When it completes, the Beacon advances to the next active or next pull.
- **Re-loaded route mid-key:** state is reconstructed from current enemy-forces percentage via `C_Scenario.GetCriteriaInfo(1)`; if the heuristic is uncertain, the user is prompted to set the current pull manually.

## 9. Configuration Surface

A new "Next Pull" section in MDT options exposes: enable / disable, role defaults override, dim upcoming pulls (slider 0–100%), Beacon enabled / size / anchor / lock, upcoming preview toggle, sync authority. A right-click context menu on the Beacon provides quick access to the most common settings.

## 10. Future Enhancements (Out of Scope)

- Minimap / world-map waypoint pointing at the centroid of the next pull (requires per-dungeon coordinate mapping from MDT canvas to world coordinates).
- Suggested pathing arrow from current player position to next pull centroid.
- Voice or TTS callout when the next pull changes.
- Per-pull cooldown reminders (e.g., "stop here for Bloodlust").
- Boss per-phase tracking.

## 11. Acceptance Criteria

The feature is considered complete when:

1. Loading any existing MDT route and entering an M+ key produces a correctly-highlighted `next` pull within one server tick.
2. Killing every mob in a pull advances `next` to the following pull within 500 ms of the last death event.
3. Manual override actions take effect immediately and survive a `/reload`.
4. Party sync produces identical `next` pull values on all addon-equipped members within one comms round-trip.
5. CPU profile (e.g., via `/run UpdateAddOnCPUUsage()`) shows no measurable regression versus baseline MDT during a full key run.
6. The Beacon correctly shows the next pull info and upcoming preview, and updates reactively on state changes.
7. Pull buttons in the sidebar display the correct state icon for each pull.
