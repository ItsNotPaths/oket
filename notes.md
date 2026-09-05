# oket release notes

Newest first. A section is one release, headed `## <version>`. The home page shows the top
section at every start, so keep it short and keep the first lines the ones that change what you
type.

## unreleased

- `ctrl+c`, `ctrl+x` and `ctrl+v` are the system clipboard, so a copy crosses between oket and
  anything else you have open.
- In a session `ctrl+c` copies too, and the interrupt moved to `ctrl+shift+c`. Both are rows:
  swap them back in `binds.conf` under `[terminal]`.
- `ctrl+k`, `ctrl+shift+k` and `ctrl+u` kill to the clipboard; `ctrl+shift+v` walks back through
  what you killed.
- A copy made with several carets pastes one piece per caret.
- `ctrl+alt+left` walks back through where you have been, `ctrl+alt+right` retraces it. It puts
  the whole screen back, not just the caret.
- `ctrl+=` and `ctrl+-` resize the text, `ctrl+0` goes back. `[font] size` in `config.conf`
  names the size a start opens at, and that is where `ctrl+0` returns to.
- `f5` in a buffer takes the file back, unsaved edits and all. It is the editor's `ed.reload`,
  so a plugin that opens files can offer the same thing.
- The editor moves its own caret: `left` and `right` are `ed.left` and `ed.right` rows in
  `binds.conf`, and `nav.left` still answers everywhere else.
- The home page is the default document. A start with no session opens it, not a listing.
- `enter` on a home row takes the offer: recovered work, a held-back plugin, a file to open.
- Two-chord binds: `ctrl+b ctrl+f`, where both chords carry a modifier.
- `alt+space` opens the menubar. Under a primer it is that primer's modifier plus space, and it
  opens on the primer's own children.
- `:width 30 50 100` is a list of percents, and `alt+w` steps to the next one.
- `alt+z` folds the block under point; `alt+/` completes off the words in the buffer.
- Carets are placed, not walked to: `ctrl+alt+down`, `alt+d`, `alt+click`, `esc` to drop them.
- Style runs say which channels they set, so an underline over a colour draws as both.
- `:open` on a file already in the ring moves to it instead of opening it twice.
