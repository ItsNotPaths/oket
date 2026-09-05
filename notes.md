# oket release notes

Newest first. A section is one release, headed `## <version>`. The home page shows the top
section at every start, so keep it short and keep the first lines the ones that change what you
type.

## unreleased

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
