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

Closing the panel keeps a half-typed note in the input for next time, and an
edit you click away from is saved rather than dropped.

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
watches it and picks up outside changes live. A typo that leaves it unreadable
doesn't cost you your notes: the panel keeps showing what it had, says what's
wrong in its header, and won't save over the file until it reads cleanly again.
Deleting the file clears your notes.

The folder is created `0700` and the file `0600`. Reading and writing go through
`store-helper.py`, which checks each folder and the file as it opens them and
works through those handles, so anything swapped in underneath is refused rather
than followed. A symlink anywhere in the path, a file or folder owned by someone
else, or a folder other users can write to stops saving, with the reason in the
header. Past 4 MB, 5000 notes, or 16,384 characters in one note, the panel shows
what it can and turns saving off rather than writing a cut-down copy back over
the file.

Uses `python3` and `inotifywait`, both part of Omarchy's base install, to read,
write, and watch the notes file.

## Settings

Inline on the widget's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "omarchy-napkin", "previewLines": 2 }
```

| Key | Default | Meaning |
|---|---|---|
| `storePath` | `~/.local/share/napkin/notes.json` | Where notes are written: an absolute path, or one starting with `~/` |
| `composeMaxLines` | `8` | Lines the input grows to before it scrolls |
| `previewLines` | `3` | Lines shown per note before it is truncated |
| `showCount` | `true` | Show the note count as a badge on the bar icon |
| `newestFirst` | `true` | List newest notes first |

## License

MIT — see [LICENSE](LICENSE).
