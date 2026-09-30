# PinTab

A small macOS menu-bar utility: a ⌘Tab-style app switcher that shows only the apps you pin.

- Real app icons in a compact floating glass panel (Liquid Glass on macOS 26, a blurred material on 14–15). The selected app's name floats just below it.
- Hold your shortcut's modifiers and press its key to cycle. Add ⇧ to go back. Release to switch.
- Pinned apps that aren't running are hidden. Their pins are kept, and they reappear when the app runs again.
- Works with a shortcut of your choice (for example ⌥⌘Tab) and no special permissions.
- Optional **⌘Tab mode** replaces the macOS app switcher. It needs Accessibility permission.
- No network access, analytics or updater.

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
| `make dmg` | Build `build/PinTab-<version>-mac-<arch>.dmg`, a drag-to-Applications disk image |
| `make run` | Build and launch `build/PinTab.app` |
| `make logs` | Stream PinTab's log messages |
| `make icon` | Regenerate `Support/AppIcon.icns` |
| `make uninstall` | Quit PinTab and remove it from `~/Applications` |
| `make clean` | Remove build output |

The app is ad-hoc signed with the fixed identifier `dev.local.PinTab`. It is a personal build for this Mac, not a distributable app. An ad-hoc signature changes with every build, so macOS treats each build as a new app. That only matters for ⌘Tab mode: its Accessibility permission has to be granted again after each install. `make install` clears the stale entry so macOS prompts again.

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
| M, or click the **⋯** button below the icons | Open the pin editor. It stays open after you release the modifiers. |

A quick tap of the shortcut switches straight to the most recently used pinned app. The panel appears only if you keep holding.

In the pin editor, click an app or press Space to pin or unpin it. Use the arrow keys to move between apps, and Return, Esc, **Done** or a click outside to close. Changes save immediately.

Only running apps can be newly pinned. A pinned app that isn't running shows dimmed and can still be unpinned.

The menu-bar icon offers **Pin/Unpin “frontmost app”**, **Manage Pinned Apps…**, **Settings…**, **Pause PinTab** and **Quit**. Settings also has **Open at login**, which is off by default.

## ⌘Tab mode

macOS keeps ⌘Tab for its own switcher and never passes it to ordinary app shortcuts. To use ⌘Tab anyway, PinTab installs an event tap, as other third-party switchers do. The event tap sees keystrokes before the system switcher does.

1. Open Settings and turn on **Use ⌘Tab**.
2. macOS asks for Accessibility permission. Turn PinTab on under **System Settings › Privacy & Security › Accessibility**. ⌘Tab starts working as soon as it's allowed; there's no need to relaunch.
3. Hold ⌘ and press Tab. Everything else works as described above, with ⌘ as the modifier and Esc to cancel.

Notes:
- **Re-granting after each build.** Each new build (ad-hoc signed) needs the permission again. If PinTab is already listed with its switch on but ⌘Tab still opens the macOS switcher, select PinTab, remove it with **−**, then turn it on again. `make install` does this reset for you.
- **Your other shortcut keeps working.** A recorded shortcut such as ⌥⌘Tab needs no permission and still works even if the permission is missing.
- **Secure text entry.** While secure text entry is on, macOS hides keystrokes from all event taps. That includes password fields and Terminal's Secure Keyboard Entry. ⌘Tab then shows the macOS switcher until secure entry ends.
- **Getting the macOS switcher back.** It's unavailable while ⌘Tab mode is on. **Pause PinTab** from the menu restores it.
- **What PinTab reads.** It acts only on ⌘Tab and on keys pressed while its switcher is open. It never records or logs typing.

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
open ~/Applications/PinTab.app --args -PinTabPreview switching   # or: managing, settings
```

## Troubleshooting

- **⌘Tab opens the macOS switcher.** PinTab lacks Accessibility permission. The menu shows "⌘Tab needs Accessibility permission"; choose **Allow ⌘Tab in Accessibility Settings…** and turn PinTab on. See ⌘Tab mode above.
- **The shortcut does nothing.** Check the menu: it shows whether the shortcut is registered. Another app or a system shortcut may already hold that combination; record a different one.
- **Logs.** Run `make logs` while reproducing, or `/usr/bin/log show --last 10m --predicate 'subsystem == "dev.local.PinTab"'`. Activation lines show whether macOS honoured the switch directly or needed the cooperative fallback.

## License

MIT. See [LICENSE](LICENSE).
