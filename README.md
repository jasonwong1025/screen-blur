# ScreenBlur

A macOS menu-bar app that blurs parts of the screen while you share it, so client
credentials and data stay hidden during a demo. Everything is keyboard-driven.

The blur is an overlay above all other windows, so it shows up in Zoom, Google Meet,
Teams, Discord, or anything else that captures the screen.

**Share your entire screen.** If you share a single window or a browser tab, the
meeting app captures only that window and the blur is left out.

## Run

    ./run.sh         # build if needed, then launch
    ./run.sh stop    # quit

## Shortcuts

| Keys      | Action                                         |
|-----------|------------------------------------------------|
| ⌃⇧B       | Blur on / off (all regions)                    |
| ⌃⇧F       | Panic: blur the full screen                    |
| ⌃⇧1–9     | Blur / reveal one region                       |
| ⌃⇧N       | New region: drag to draw, Esc when done        |
| ⌃⇧E       | Edit regions: drag to move, yellow corner to resize, right-click to delete |
| ⌃⇧A       | Auto-detect sensitive text on / off            |
| ⌃⇧S       | Save regions as a preset                       |
| ⌃⌥⇧1–9    | Load preset 1–9                                |
| ⌃⇧⌫       | Remove all regions                             |
| ⌃⇧/       | Show the shortcut list                         |

The same actions are in the menu-bar icon, along with a blackout style (solid black
instead of blur) and the custom-terms list.

## Auto-detect

Screenshots each display about twice a second, runs on-device OCR, and blurs emails,
phone numbers, card numbers, API keys and tokens, `password: value` pairs, and any
custom terms you add. Nothing leaves the machine.

- Needs Screen Recording permission (System Settings → Privacy & Security). The app is
  ad-hoc signed, so macOS asks again after each rebuild.
- It lags: newly shown text is visible for up to a second before it is covered. Use
  manual regions for anything that must never be seen, and auto-detect as a backup.

## Limits

- Regions are fixed screen positions. They do not follow content when you scroll or
  move a window.
- Regions and presets are stored in `~/Library/Application Support/ScreenBlur/state.json`.
