# omarchy-napkin

Quick notes for the [Omarchy](https://omarchy.org/) shell — a Quickshell bar
widget for the thought you need to write down right now, before it's gone.

Click the bar icon, type, press Enter. No save button, no file to name, no
window to find again.

## Using it

The input grows as you type — one line to eight, then it scrolls. **Enter**
files the note, **Shift+Enter** starts a new line inside it.

Click any note for its menu: **Copy** puts it on the clipboard, **Edit** opens
it in place, **Delete** removes it with an undo link in the header for eight
seconds.

The bar icon carries the note count; hover it to see the most recent few.

## Keyboard

| Key | Effect |
|---|---|
| `Enter` | File the note, or activate the highlighted menu row |
| `Shift+Enter` | Newline inside the note |
| `↓` `↑` / `j` `k` | Move into the list and through it, while the input is empty |
| `Enter` on a note | Open its menu |
| `y` / `x` / `u` | Copy / delete the highlighted note, undo the last delete |
| `Esc` | Clear a draft, then leave the list, then close |

## Install

```bash
omarchy plugin add https://github.com/sudoAPWH/omarchy-napkin.git --enable --yes
```

By hand instead:

```bash
git clone https://github.com/sudoAPWH/omarchy-napkin.git ~/.config/omarchy/plugins/omarchy-napkin
omarchy-shell shell rescanPlugins
omarchy plugin enable omarchy-napkin --section right
```

The directory name must match the `id` in `manifest.json`. Move the widget with
`omarchy bar move omarchy-napkin --section right`.

## Removing it

```bash
omarchy plugin remove omarchy-napkin --yes
```

To take it off the bar but keep it installed, `omarchy plugin disable
omarchy-napkin` instead.

Removal leaves your notes alone. Delete them yourself if you want them gone:

```bash
rm -rf ~/.local/share/napkin
```

## Notes on disk

```
~/.local/share/napkin/notes.json
```

One JSON file, safe to edit by hand or keep in a dotfiles repo — the panel
watches it and picks up outside changes live.

## Settings

Inline on the widget's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "omarchy-napkin", "previewLines": 2 }
```

| Key | Default | Meaning |
|---|---|---|
| `storePath` | `~/.local/share/napkin/notes.json` | Where notes are written |
| `composeMaxLines` | `8` | Lines the input grows to before it scrolls |
| `previewLines` | `3` | Lines shown per note before it is truncated |
| `showCount` | `true` | Show the note count beside the bar icon |
| `newestFirst` | `true` | List newest notes first |

## License

MIT — see [LICENSE](LICENSE).
