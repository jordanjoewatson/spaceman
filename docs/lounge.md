# Lounge

Lounge is an optional plugin (`Plugins/lounge/`) that turns the Mac into a
living-room console: a fullscreen home screen you drive with a game controller.

## Using it

- **Open / close:** the controller's home button (PS / Xbox / Guide). Spaceman
  asks macOS not to use that button for its own gesture. If it doesn't work on your
  controller, use the fallback chord Options+Share
  (PlayStation) / Menu+View (Xbox), which can be turned off in Settings ▸ Lounge.
  ⌃⌥G toggles Lounge from the keyboard.

  macOS swallows the home button before the GameController framework sees
  it, so Lounge reads it from the controller's raw HID reports instead
  (DualSense, DualShock 4, and the standard Consumer "AC Home" usage). macOS
  still runs its own action too: turn it off in System Settings → Game
  Controllers → your controller, or Apple Arcade opens alongside Lounge.
- **Navigate:** D-pad or left stick moves between tiles. South (✕ / A) opens,
  hold it to remove a tile, West (◻ / X) quits a running tile, L1/R1 move one
  Space left/right (via the system's ⌃← / ⌃→ shortcuts). East (◯ / B) only
  cancels prompts: it never leaves a game or page, so the game keeps it. The
  hint bar shows your controller's own button glyphs. Arrow keys, Return,
  Escape and Delete work too.
- **In a page** (web or Docker Compose entries): every button goes to the page
  except L2/R2 (LT/RT), which zoom it out and in; the zoom is remembered per
  entry. Browsers only expose a controller to a page after a button is pressed
  on it, so the first press in a freshly opened page may only "wake" the pad.
- **Leaving an app:** press home in a game and Lounge appears over it; the game
  keeps running and its tile shows Resume / Quit. Press home again to go back.
  The **Exit Lounge** tile closes Lounge and returns to the normal desktop.

## Library

Nothing appears unless you add it — there is no auto-discovery. Add, remove and
reorder entries in Settings ▸ Lounge, or with the **Add** tile in Lounge. While
the library is empty, a **Suggested** row shows installed apps whose
`LSApplicationCategoryType` is a games category; they are only added when you
pick one.

The library is `~/Library/Application Support/Spaceman/Plugins/lounge/library.json`:

```json
{
  "version": 1,
  "entries": [
    { "id": "…", "title": "Celeste",
      "launch": { "type": "app", "bundleID": "com.example.celeste", "path": "/Applications/Celeste.app" } },
    { "id": "…", "title": "Arcade",
      "launch": { "type": "web", "url": "https://arcade.example.com" } },
    { "id": "…", "title": "Game jam",
      "launch": { "type": "dockerCompose", "file": "/Users/me/jam/compose.yaml", "port": 8080 } }
  ]
}
```

Entries that fail validation or use an unknown launch type are skipped on
load. A file from a newer version is left untouched.

## Launch types

Launch types are a closed set filled in through pickers and validated fields.
**There are no free-text commands and no shell, ever.** Process-based types
will run through `Process` with fixed argument arrays built from validated
values.

| Type | Status | What it does |
| --- | --- | --- |
| `app` | Available | Opens a chosen `.app` by bundle ID, puts its window in fullscreen, and keeps it out of tiling. |
| `web` | Available | Opens an http(s) URL in Lounge's own fullscreen web view, so the controller and home button keep working. |
| `steam` | Planned | Launches a Steam game by app ID. |
| `dockerCompose` | Available | For your own projects. Pick a compose file in Settings ▸ Lounge; the port is read from its `ports:` and can be edited. Runs `docker compose -f <file> up -d`, waits for the port, shows `http://localhost:<port>` in the web view, and runs `down` when you quit it (or when Spaceman quits). |
| `dockerImage` | Planned | Runs a validated image reference and shows its port in the web view. |

The first time a Docker Compose entry launches, Lounge shows the exact command
and runs it only after you confirm; it asks again if the entry's file changes.
`docker` is looked up at fixed install locations (Docker Desktop, Homebrew,
OrbStack) and run without a shell, with the compose file as a single argument.

Also planned: a now-playing card.

## Building without it

```sh
./build-app.sh --without lounge
```

Lounge is the only code that uses the GameController framework, so a build
without it doesn't link that framework.
