# omarchy-napkin

Quick notes for the [Omarchy](https://omarchy.org/) shell — a Quickshell bar
widget for the thought you need to write down *right now*, before it's gone.

Click the bar icon, type, press Enter. There is no save button, no file to
name, and no window to find again. The note is on disk before you've looked
away.

## The panel

```
┌─ Napkin ──────────────────── 4 notes ─┐
│ ┌───────────────────────────────────┐ │
│ │ write it down…                    │ │
│ └───────────────────────────────────┘ │
│                                       │
│  call the landlord back               │
│  3m ago                               │
│                                       │
│  ILP-3390 needs a repro — only on     │
│  cold start, ~1 in 5                  │
│  1h ago                               │
└───────────────────────────────────────┘
```

The input grows as you type — one line to eight, then it scrolls. **Enter**
files the note, **Shift+Enter** starts a new line inside it.

Click any note for its menu: **Copy** puts it on the clipboard, **Edit** opens
it in place in the same growing box, **Delete** removes it with an undo link in
the header for eight seconds.

The bar icon carries the note count. Hovering it lists the most recent few, so
the common "what was that thing?" never needs a click.

## Keyboard

The input has focus the moment the panel opens, so the fast path is just
type-and-Enter. Everything else is reachable without the mouse:

| Key | Effect |
|---|---|
| `Enter` | File the note (or activate the highlighted menu row) |
| `Shift+Enter` | Newline inside the note |
| `↓` `↑` / `j` `k` | Move into the list and through it — while the input is empty |
| `Enter` on a note | Open its menu |
| `y` | Copy the highlighted note |
| `x` | Delete the highlighted note |
| `u` | Undo the last delete |
| `Esc` | Clear a draft, then leave the list, then close |

`Esc` never closes the panel while there is unsent text in the box — losing
half a typed thought is the one failure this widget exists to prevent.

## Install

The plugin is the repository, so it installs the way any third-party Omarchy
plugin does:

```bash
omarchy plugin add https://git.hutlet.ca/ahutlet/omarchy-napkin.git --enable --yes
```

To install a working copy by hand instead:

```bash
git clone https://git.hutlet.ca/ahutlet/omarchy-napkin.git ~/.config/omarchy/plugins/omarchy-napkin
omarchy-shell shell rescanPlugins
omarchy plugin enable omarchy-napkin --section right
```

The directory name must match the `id` in `manifest.json`. Move the widget
around with `omarchy bar move omarchy-napkin --section right`.

## Where notes are kept

```
~/.local/share/napkin/notes.json
```

One JSON file, pretty-printed, safe to edit by hand or keep in a dotfiles
repo — the panel watches it and picks up outside changes live.

Note the `napkin/` namespace rather than `omarchy/napkin/`. On an installed
Omarchy system `~/.local/share/omarchy` is a **symlink to the root-owned
package tree** at `/usr/share/omarchy`, so the obvious-looking path is not
writable. If the store directory ever can't be created, the panel says so in
its header rather than silently dropping what you type.

Notes live under `XDG_DATA_HOME` rather than the state directory the clipboard
history uses, because these are documents you wrote and expect to survive a
cache wipe — not derived state the shell can rebuild.

## Settings

Settings live inline on the widget's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "omarchy-napkin", "previewLines": 2, "newestFirst": true }
```

| Key | Default | Meaning |
|---|---|---|
| `storePath` | `~/.local/share/napkin/notes.json` | Where notes are written |
| `composeMaxLines` | `8` | Lines the input grows to before it scrolls |
| `previewLines` | `3` | Lines shown per note before it is truncated |
| `showCount` | `true` | Show the note count beside the bar icon |
| `newestFirst` | `true` | List newest notes first |

## Development

Omarchy loads plugins from `~/.config/omarchy/plugins/<id>/`. To work from a
checkout elsewhere, point that path at it:

```bash
ln -s ~/Projects/napkin ~/.config/omarchy/plugins/omarchy-napkin
```

Apply changes with `omarchy restart shell`. Hot-reload does not fire for a
symlinked plugin directory, and `rescanPlugins` can re-run the previous build
of a QML file.

**Do not reload plugins while the session is locked.** The lock surface lives
in the same `omarchy-shell` process; reloading under it can strand the lock
plugin, and Quickshell treats "tried to show lockscreen surfaces without active
lock" as fatal — taking the whole shell, and your lock screen, down with it.

Check the manifest and the QML before restarting:

```bash
omarchy plugin validate .
/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell Panel.qml
```

Note the full path: `/usr/bin/qmllint` on this system is a stub that validates
nothing and exits 0 even on a syntax error. The `qs.Commons` / `qs.Ui` imports
only resolve if the import root mirrors the module name, so point `-I` at a
directory containing `qs/Commons` and `qs/Ui` symlinks for a fully typed pass.

## How it works

`Notes.js` owns the store: parsing, id minting, ordering, and the relative
timestamps. It is pure functions, so the QML stays declarative and the
persistence rules live in one readable place.

Every mutation returns a **new** array rather than splicing in place — QML only
re-evaluates a `var` property binding when the reference changes, so in-place
edits would leave the list showing stale rows.

Writes are debounced 400ms and flushed on close and on destruction. Filing a
note is one write, but editing one in place would otherwise be a write per
keystroke. The file is watched, and the panel's own write comes back through
that watcher — identical content is a no-op, so the echo can't clobber an edit
made in the window between the write and the notification.

`GrowingInput.qml` is the expanding text box, built on a `Flickable` with
`TextArea.flickable` — that pairing is what buys cursor-follow scrolling once
the content passes `composeMaxLines`. A bare `TextArea` with a capped height
would clip the line you are typing on. Its chrome is copied from the kit's
single-line `TextField` so it reads as part of the same family.

The action menu is drawn as a plain `Item` inside the panel rather than its own
window. The panel is already a full-screen layer surface, so floating a card
inside it keeps the menu on the same surface as the list — nothing to position,
focus, or lose to a compositor stacking rule — and being a sibling of the list
rather than a child of the row, it can overhang the list's `Flickable` instead
of being clipped by it.

## License

MIT — see [LICENSE](LICENSE).
