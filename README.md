# SCT Control

Control Blizzard's floating/scrolling combat text - what's shown, where, how fast, how big.

Incoming text can be split into separate areas (heals, aura gains/fades, resource gains, other) that you place independently with `/sctc move`. Outgoing numbers over your target are drawn by the game engine, so they can be toggled and resized but not moved.

## Releasing

On GitHub, go to Actions → Package and release → Run workflow and enter a version like `v1.0.1` (or push a tag like that). GitHub Actions packages the addon and uploads it to CurseForge.
