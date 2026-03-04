# SourceMod Paint Plugin

Plugin for `Counter-Strike: Source` servers that lets players paint decals on walls. Designed primarily for bhop servers, but probably can be used for other types of servers.

## Features

### Paint Modes

- **Shared (server-side):** Paint is visible to all players on the server. Decals are replayed to clients who join mid-map.
- **Client-side:** Paint is visible only to you. Supports saving and loading per player per map via DB.

Players can switch between modes at any time.

### Colors

14 colors plus a random option:

Black, Blue, Brown, Cyan, Dark Green, Green, Light Blue, Light Pink, Orange, Pink, Purple, Red, White, Yellow, Random

### Sizes

5 sizes:

| Size | Dimensions |
|---|---|
| Very Small | 8×8 |
| Small | 16×16 |
| Medium | 32×32 |
| Large | 64×64 |
| Very Large | 128×128 |

Color and size preferences are saved as client cookies and persist across sessions.

### Eraser

Highlights the nearest decal with a glow effect and erases it on `+use`. Works on whichever buffer (shared or client-side) is currently active. "Erase All" clears the entire active buffer.

### Save / Load (Client-side mode only)

Decals are saved to a SQLite database keyed by SteamID and map name. Saving overwrites the previous save for that map. Saved decals are automatically loaded when joining a server if client-side mode is enabled.

## Commands

| Command | Description |
|---|---|
| `sm_paint` | Open the paint menu |
| `sm_paintcolor` | Open the color picker |
| `sm_paintsize` | Open the size picker |
| `sm_clientsidepaint` | Toggle client-side paint mode |
| `+paint` / `-paint` | Start/stop painting (bind to a key) |

### Example Keybind

```
bind mouse3 +paint
```

## Technical Details

- Decal buffer capacity: 2048 decals per buffer (shared and per-player client-side).
- Buffers are ring buffers — oldest decals are overwritten when full.
- Decals are replayed to connecting clients 1 second after joining.
- Paint position is sampled every 100 ms; a minimum distance threshold prevents duplicate decals when standing still.
