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
| Hold ⌃⌥   | Peek: reveal the blur under the pointer        |
| ⌃⇧N       | New region: drag to draw, Esc when done        |
| ⌃⇧C       | Click an item to blur it, Esc when done        |
| ⌃⇧E       | Edit regions: drag to move, yellow corner to resize, right-click to delete |
| ⌃⇧A       | Auto-detect sensitive text on / off            |
| ⌃⇧T       | Blur all text on / off                         |
| ⌃⇧V       | Blur only for viewers on / off                 |
| ⌃⇧S       | Save regions as a preset                       |
| ⌃⌥⇧1–9    | Load preset 1–9                                |
| ⌃⇧⌫       | Remove all regions                             |
| ⌃⇧/       | Show the shortcut list                         |

Peek lifts only the blur the pointer is over, after a fifth of a second of holding
⌃⌥, and puts it back the moment the pointer leaves it or you let go. It works on drawn,
picked and auto-detected blurs, not on the full-screen panic blur. The blur is lifted
for viewers too, so use it when you mean to show the item.

The same actions are in the menu-bar icon, along with a blackout style (solid black
instead of blur) and the custom-terms list.

## Click to blur

⌃⇧C turns the pointer into a picker: the item under it is outlined in yellow, and a
click blurs it instead of activating it. It works on anything macOS exposes through
Accessibility: app controls and text, desktop icons, menu-bar items, browser toolbars
and web page content.

- Needs Accessibility permission (System Settings → Privacy & Security). `build.sh`
  signs with your Apple Development certificate when you have one, so the grant survives
  rebuilds; with an ad-hoc signature you have to remove and re-add the app after each one.
- A picked region follows its item when you scroll or move the window, and hides when
  the item scrolls out of its window. It belongs to that window: it disappears when you
  swipe to another Space or full-screen app, switch browser tab, minimise or hide the
  window, or cover the item with another window, and comes back when the item does.
  It trails fast scrolling, and a swipe, by a frame or two.
- A drawn region belongs to the window it was drawn over in the same way, and moves with
  that window, but keeps its place inside it rather than following scrolled content.
  Drawn over the bare desktop it stays a fixed box on every Space. Following browser
  tabs needs the Accessibility permission; the rest works without it.
- If the page re-renders and the item is replaced, the box keeps its last place inside the window.
  After a relaunch, and in presets, picked regions are plain fixed boxes.

## Auto-detect

Screenshots each display about twice a second, runs on-device OCR, and blurs emails,
phone numbers, card numbers, API keys and tokens, `password: value` pairs, and any
custom terms you add. Nothing leaves the machine.

⌃⇧T blurs all text instead: every piece of text the OCR finds on any display, in any
app, web page or on the desktop, in any language, with neighbouring lines joined into
one blur. It is off again after a relaunch.

- Needs Screen Recording permission (System Settings → Privacy & Security). With an
  ad-hoc signature macOS asks again after each rebuild.
- It lags: newly shown text is visible for up to a second before it is covered, so
  text shows briefly while you scroll or switch windows. Use manual regions for anything
  that must never be seen, and detection as a backup.
- OCR misses some text, such as very small, low-contrast or stylised lettering.

## Blur only for viewers

A meeting app records exactly what a display shows, so a blur cannot be in the
recording without also being on your screen. ⌃⇧V works around that: it adds a
software-only display called "ScreenBlur" that shows a live copy of your main display
with the blurs painted in, and takes the blurs off your real screen. In the meeting,
share the "ScreenBlur" screen instead of your own. You still see the boxes in edit
mode (⌃⇧E), and none of ScreenBlur's own windows appear in the copy.

- Needs Screen Recording permission, and macOS shows its recording indicator while
  it is on.
- Share the "ScreenBlur" screen, not your real one: your real screen has no blur on it
  in this mode.
- macOS treats the extra display as a real monitor. It is parked corner to corner with
  the main display so the pointer does not slide onto it, but a window can still be
  sent there, where you cannot see it.
- It copies the main display only, and adds a frame or two of delay for viewers.
- Off again after a relaunch. It relies on an undocumented macOS feature.

## Limits

- Drawn regions keep their place inside their window. They do not follow content when
  you scroll; regions picked with ⌃⇧C do.
- Regions and presets are stored in `~/Library/Application Support/ScreenBlur/state.json`.
