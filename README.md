# ScreenBlur

A macOS menu-bar app that blurs parts of your screen while you share it, so
credentials, client data and anything else private stay hidden during a demo or a
call. Everything is driven from the keyboard.

- **Draw a box** over anything, or **click an item** to blur exactly that button, line
  of text or icon.
- Blurs **belong to their window**: they move with it and disappear when you switch
  Space, tab or app.
- **Auto-detect** emails, phone numbers, card numbers, keys and tokens, or blur
  **all text** on screen.
- **Blur only for viewers**: keep your own screen clear while the people watching see
  the blur.
- **Peek** under a blur by holding a key, and **panic** to cover the whole screen.

## Requirements

- macOS 14 or later
- A Swift toolchain (Xcode or the Command Line Tools) to build it

## Run

    ./run.sh         # build if the source changed, then launch
    ./run.sh stop    # quit

ScreenBlur lives in the menu bar and has no Dock icon. The shortcut list opens on
first launch, and any time with ⌃⇧/.

`build.sh` signs the app with your Apple Development or Developer ID certificate when
one is installed. That matters because macOS ties permission grants to the signature:
with a stable one you grant each permission once, while an ad-hoc signature changes on
every rebuild and the grants silently stop applying. Set `CODESIGN_IDENTITY` to choose
an identity, or to `-` for ad-hoc.

## Quick start

1. Press ⌃⇧N and drag a box over what you want hidden. Esc when you are done.
2. Share your **entire screen** in the meeting app.
3. Press ⌃⇧B to turn every blur off and on, or ⌃⇧F to cover the whole screen at once.

## Shortcuts

| Keys      | Action                                                          |
|-----------|-----------------------------------------------------------------|
| ⌃⇧B       | Blur on / off (all regions)                                     |
| ⌃⇧F       | Panic: blur the full screen                                     |
| ⌃⇧1–9     | Blur / reveal one region                                        |
| Hold ⌃⌥   | Peek: reveal the blur under the pointer                         |
| ⌃⇧N       | New region: drag to draw, Esc when done                         |
| ⌃⇧C       | Click an item to blur it, Esc when done                         |
| ⌃⇧E       | Edit regions: drag to move, yellow corner to resize, right-click to delete |
| ⌃⇧A       | Auto-detect sensitive text on / off                             |
| ⌃⇧T       | Blur all text on / off                                          |
| ⌃⇧V       | Blur only for viewers on / off                                  |
| ⌃⇧S       | Save regions as a preset                                        |
| ⌃⌥⇧1–9    | Load preset 1–9                                                 |
| ⌃⇧⌫       | Remove all regions                                              |
| ⌃⇧/       | Show the shortcut list                                          |

The same actions are in the menu-bar icon. If another app already owns one of these
shortcuts, the shortcut list says which, and the menu still works.

## Which screen to share

| Mode                          | Share this                  | Why                                              |
|-------------------------------|-----------------------------|--------------------------------------------------|
| Normal                        | Your entire screen          | The blur is an overlay above every window.       |
| Blur only for viewers (⌃⇧V)   | The screen named "ScreenBlur" | The blur exists only in that copy of your screen. |

Sharing a single window or a browser tab leaves the blur out in either mode, because
the meeting app then captures only that window.

## Regions

A region is one blurred box. There are two ways to make one.

**Draw it (⌃⇧N).** Drag a box anywhere. It attaches to the window under its centre and
keeps its place inside that window, so it moves when the window moves. It does not
follow content that scrolls. Drawn over the bare desktop, it is a fixed box on every
Space.

**Click an item (⌃⇧C).** The pointer becomes a picker: the item under it is outlined
in yellow, and a click blurs it instead of activating it. This works on anything
macOS exposes through Accessibility, including app controls and text, desktop icons,
menu-bar items, browser toolbars and web page content. A picked region follows its
item as you scroll, and hides when the item scrolls out of its window.

Either kind belongs to its window. It disappears when you:

- swipe to another Space or a full-screen app
- switch browser tab
- minimise the window or hide its app
- cover the item completely with another window

and it comes back when the item does.

Good to know:

- A region trails fast scrolling, and a Space swipe, by a frame or two.
- If a page re-renders and replaces a picked item, the box keeps its last place inside
  the window.
- Moving a region in edit mode re-attaches it to whatever window it lands on.
- Following browser tabs needs the Accessibility permission. A freshly drawn box takes
  about a second to learn which tab it is on.
- Tabs inside apps that are one web page per window, such as VS Code, are not told
  apart.
- After a relaunch, and in presets, regions are plain fixed boxes that follow nothing.

### Peek

Hold ⌃⌥ for a fifth of a second to lift the blur the pointer is over. It returns the
moment the pointer leaves it or you let go. Peek works on drawn, picked and detected
blurs, but never on the panic blur, and not in edit mode.

Peek lifts the blur for everyone, viewers included. Use it when you mean to show the
item.

### Presets and style

- **Presets** store the current set of regions in one of nine slots. Save with ⌃⇧S,
  load with ⌃⌥⇧1–9, and delete from the menu. Saving to a used slot replaces it.
- **Blackout Instead of Blur**, in the menu, swaps the clear-glass blur for solid
  black. Use it when the shape of large text behind a blur gives too much away.

## Detection

Both detection modes screenshot each display about twice a second and find text with
on-device OCR. Nothing leaves the machine.

**Auto-detect (⌃⇧A)** blurs text that looks sensitive:

- email addresses and international phone numbers
- card numbers
- API keys and tokens (AWS, GitHub, Slack, JWTs and `sk-` style keys)
- the value in `password: value` style pairs
- any custom terms you add under **Custom Terms to Auto-blur…** in the menu

**Blur all text (⌃⇧T)** blurs every piece of text found, in any app, web page or on
the desktop, in any language. Neighbouring lines are joined into one blur. This mode
is off again after a relaunch.

Detection is a backup, not a guarantee:

- It lags. Newly shown text is visible for up to a second before it is covered, so
  text shows briefly while you scroll or switch windows.
- OCR misses some text, such as very small, low-contrast or stylised lettering.

For anything that must never be seen, use a drawn or picked region.

## Blur only for viewers

A meeting app records exactly what a display shows, so a blur cannot be in the
recording without also being on your screen. ⌃⇧V works around that. It adds a
software-only display named "ScreenBlur" that shows a live copy of your main display
with the blurs painted in, and takes the blurs off your real screen.

1. Press ⌃⇧V.
2. In the meeting app, share the screen named "ScreenBlur" instead of your own.
3. Work as usual. You see your boxes only in edit mode (⌃⇧E), and none of ScreenBlur's
   own windows, outlines or messages appear in the copy.
4. Press ⌃⇧V again to put the blurs back on your own screen.

Good to know:

- **Share the right screen.** In this mode your real screen has no blur on it, so
  sharing it by mistake shows everything.
- macOS treats the extra display as a real monitor. It is parked corner to corner with
  the main display so the pointer does not slide onto it, but a window can still be
  sent there, where you cannot see it.
- Only the main display is copied, and viewers see it a frame or two late.
- Panic, auto-detect and blur-all-text go into the copy too, so they also stop showing
  on your own screen while the mode is on.
- macOS shows its screen-recording indicator while the mode is on.
- The mode is off again after a relaunch.

## Permissions

Grant these under System Settings → Privacy & Security. ScreenBlur asks the first
time a feature needs one.

| Permission                       | Needed for                                                    |
|----------------------------------|---------------------------------------------------------------|
| None                             | Drawing, editing, panic, peek and presets                     |
| Accessibility                    | Click to blur (⌃⇧C), and following browser tabs               |
| Screen & System Audio Recording  | Auto-detect, blur all text, and blur only for viewers         |

Screen Recording takes effect only after the app is relaunched. If a permission looks
granted but the app still asks for it, the grant belongs to an older build with a
different signature. Remove ScreenBlur from the list, or run
`tccutil reset Accessibility com.jason.screenblur` (or `ScreenCapture`), then grant it
again.

## Under the hood

- Regions and presets are stored in
  `~/Library/Application Support/ScreenBlur/state.json`.
- ScreenBlur uses a few undocumented macOS features: keeping blur windows on screen
  during Space transitions, the tint-free window blur, reading a window's ID from
  Accessibility, and the software display. Each falls back or switches itself off if
  macOS stops providing it, but a future macOS release could change how they behave.

| Path                                   | What it holds                                         |
|----------------------------------------|-------------------------------------------------------|
| `Sources/ScreenBlur/main.swift`        | The app: regions, windows, shortcuts and the menu     |
| `Sources/ScreenBlur/Picker.swift`      | Accessibility lookups and click capture               |
| `Sources/ScreenBlur/AutoDetect.swift`  | Screen capture and OCR for both detection modes       |
| `Sources/ScreenBlur/ShareFeed.swift`   | The software display and the live copy shown on it    |
| `Sources/ScreenBlur/Compositor.swift`  | Painting the blur into captured frames                |
| `Sources/CVirtualDisplay/`             | Declarations for the software display classes         |
