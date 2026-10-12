# LidShot

A menu bar app with two features taken from Vorssaint: keep the Mac awake with the lid closed, and take screenshots you can annotate.

## Build

```sh
./build.sh            # builds build/LidShot.app
./build.sh --install  # copies it to /Applications and launches it
```

Requires the Xcode Command Line Tools, macOS 13 or later.

## Closed-lid mode

- **⌥⇧L** (configurable) or the menu toggles it. It runs `pmset -a disablesleep 1` and holds an idle-sleep assertion.
- **Включить переключение без пароля…** installs `/etc/sudoers.d/lidshot`. That file lets your user run only
  `pmset -a disablesleep 0|1` without a password. Timers and the battery auto-off need it, because
  nobody can type a password while the lid is closed.
- Quitting the app turns the mode off.

## Screenshots

- **⌥⇧4** captures an area. Press Space to switch to window capture.
- **Горячие клавиши…** in the menu lets you rebind both shortcuts (area capture and closed-lid mode), or
  turn either one off.
- Tools (key in brackets): Select (V), Arrow (A), Line (L), Rectangle (R), Ellipse (O), Pen (P),
  Highlighter (H), Text (T), Step number (N), Pixelate (B), Crop (C).
- Hold Shift to snap lines to 45° and draw squares or circles. Changing the colour or width restyles the
  selected shape. Double-click text to edit it. Delete removes the selected shape.
- Return copies the image and closes the window. ⌘C copies, ⌘S saves to a file (the last folder is
  remembered), and ⌘Z / ⇧⌘Z undo and redo.
- The link button uploads the image to litterbox.catbox.moe (anonymous, public, auto-deleted after 1 h,
  12 h, 24 h or 3 days) and copies the URL. Anyone with the link can open the image until it expires.
