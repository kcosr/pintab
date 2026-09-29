# PinTab

A small macOS menu-bar utility: a ⌘Tab-style app switcher that shows only the apps you pin.

- Real app icons in a floating glass panel (Liquid Glass on macOS 26, a blurred material on 14–15).
- Hold your shortcut's modifiers and press its key to cycle. Add ⇧ to go back. Release to switch.
- Pinned apps that aren't running are hidden. Their pins are kept, and they reappear when the app runs again.
- Needs no Accessibility or Input Monitoring permission. No network access, analytics or updater.

## Requirements

- macOS 14 or later (developed on macOS 26).
- Swift 6.2 or later. The Command Line Tools are enough; Xcode is optional.

## Build and install

```sh
make install     # build release, assemble PinTab.app, sign ad hoc, copy to ~/Applications and launch
```

Other targets:

| Command | What it does |
| --- | --- |
| `make test` | Run the PinTabCore test suite (swift-testing) |
| `make app` | Build `build/PinTab.app` without installing |
| `make run` | Build and launch `build/PinTab.app` |
| `make logs` | Stream PinTab's log messages |
| `make icon` | Regenerate `Support/AppIcon.icns` |
| `make uninstall` | Quit PinTab and remove it from `~/Applications` |
| `make clean` | Remove build output |

The app is ad-hoc signed with the fixed identifier `dev.local.PinTab`. It is a personal build for this Mac, not a distributable app. PinTab needs no privacy permissions, so re-signing on every build has no side effects.

To sign with a certificate instead, pass its name: `make install SIGN_IDENTITY="My Code Signing Cert"`. A self-signed certificate made in Keychain Access works.

Settings live in the `dev.local.PinTab` defaults domain. Remove them with `defaults delete dev.local.PinTab`.

## Using PinTab

1. On first launch, Settings opens. Click **Record Shortcut** and press a combination such as ⌥⌘Tab.
   - The shortcut must include ⌘ or ⌃.
   - ⇧ is reserved for going backwards.
   - Combinations macOS already uses are rejected: ⌘Tab, ⌘\`, ⌘Space, and anything whose ⇧ variant is a screenshot shortcut.
2. Press the shortcut. With nothing pinned yet, the **Pinned Apps** editor opens. Click running apps to pin them, then click **Done**.
3. Hold the modifiers and press the key to show the switcher:

| While the switcher is open | Result |
| --- | --- |
| Key again / ⇧ + key | Next / previous app (wraps) |
| ← → | Move the selection |
| Release the modifiers | Switch to the selected app |
| Click an icon | Switch to that app |
| Esc or `.` | Cancel. With ⌥⌘ shortcuts, use `.`, because macOS reserves ⌥⌘Esc for Force Quit. |
| M, or click **Manage…** | Open the pin editor. It stays open after you release the modifiers. |

A quick tap of the shortcut switches straight to the most recently used pinned app. The panel appears only if you keep holding.

In the pin editor, click an app or press Space to pin or unpin it. Use the arrow keys to move between apps, and Return, Esc, **Done** or a click outside to close. Changes save immediately.

Only running apps can be newly pinned. A pinned app that isn't running shows dimmed and can still be unpinned.

The menu-bar icon offers **Pin/Unpin “frontmost app”**, **Manage Pinned Apps…**, **Settings…**, **Pause PinTab** and **Quit**. Settings also has **Open at login**, which is off by default.

## Behaviour notes

- **Order.** Apps are ordered by recent use, which PinTab tracks from the moment it starts. Highlighting, cancelling and PinTab's own windows don't change it.
- **What switching does.** PinTab activates the app. Minimized or windowless apps come to the front without reopening windows, as with ⌘Tab. It never launches an app.
- **Spaces.** Space changes follow macOS's own activation rules and your Mission Control settings.
- **Where the panel appears.** On the display that has the pointer.

## Project layout

```
Sources/PinTabCore/   Pure logic (Foundation only): state machine, ordering, shortcuts, preferences
Sources/PinTab/       AppKit/SwiftUI app: hotkeys, panel, activation, settings, menu bar
Tests/PinTabCoreTests Swift Testing suite for PinTabCore
Support/Info.plist    Bundle template (LSUIElement menu-bar app)
scripts/make-app.sh   Assembles and signs the .app bundle
```

The interaction model is an explicit state machine (`SwitcherMachine`), which is idle, switching or managing. The app layer feeds it events and performs the effects it returns: show, hide, activate and set pinned.

Input handling works like this:
- The shortcut is registered with the Carbon hotkey API.
- A non-activating key panel receives Esc, arrows and modifier changes without taking focus from the current app.
- A 60 Hz modifier poll during a session is the safety net for a release that happens before the panel gets focus.

To inspect the panels without pressing keys, launch with a preview argument. The panel shows for six seconds and nothing is activated:

```sh
open ~/Applications/PinTab.app --args -PinTabPreview switching   # or: managing
```

## Troubleshooting

- **The shortcut does nothing.** Check the menu: it shows whether the shortcut is registered. Another app or a system shortcut may already hold that combination; record a different one.
- **Logs.** Run `make logs` while reproducing, or `/usr/bin/log show --last 10m --predicate 'subsystem == "dev.local.PinTab"'`. Activation lines show whether macOS honoured the switch directly or needed the cooperative fallback.

## License

MIT. See [LICENSE](LICENSE).
