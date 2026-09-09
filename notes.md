# oket release notes

Newest first. A section is one release, headed `## <version>`. The home page shows the top
section at every start, so keep it short and keep the first lines the ones that change what you
type.

## 0.3

- `:harness <file> <plugin>...` runs a file of steps in a second oket with the crash net off, so
  a plugin bug drops a core instead of being recovered out from under you. A step is a command
  line, a chord (`> ctrl+shift+k`), text to type, or a check (`! lines == 12`); a check that
  fails names its line in N0, where `enter` opens it. A plugin is a source directory to build or
  the name of one you have installed, and nothing else loads.
- `:get` also answers `message`, `lines`, `text`, `desc` and `spans`. `spans` says who published
  each colour run, which nothing else shows.
- `:oket update` fetches the latest release and installs it, in N0. Then it restarts.
- `ctrl+f` filters a list: the file browser, the theme list, the grammar list. `esc` clears
  the filter. Typing without it still edits the name.
- `[theme] name` in `config.conf` picks a theme, and the switch shows on the next frame.
  gruvbox ships. A helix theme file dropped into the themes folder works as it is.
- `:ring themer` lists the themes you have and the ones in the helix repo. `enter` stages the
  chain that installs and switches, `del` the one that removes. You read the line before you
  run it.
- Chains take `||`: the step after it runs when the step before failed, the way `&&` runs on
  success.
- `:get panels` puts kernel state on the pipe (also panel, slot, slots, kind, file).
  `:set <section>.<key> <value>` changes a setting for the session. `:do` runs the lines piped
  into it, so `:get panels | awk '...' | :do` is a loop.
- `@*` targets every panel, and `:close #*` closes every slot.
- `[alias] name = line` in `config.conf` names a chain as a new verb. `panel.equalize` ships
  as one: it gives every panel an equal share of the strip.
- The hello and popup plugins folded into one example plugin.
- The helper library is split by section, and `stage.sh` finds every helper file itself.

## released

- `alt+q` closes the panel along with the slot. The last panel standing lands on a home page
  instead, so closing the last document no longer drops you on the glyph-check screen.
- Hold `alt` and the ring is drawn down the side of the panel: the lane you are in, then its
  slots in the numbers `alt+1..9` uses. `[switcher] show = numbers` cuts it to the digits.
- N0 is spelled `0` now and not `#`. The bind row is `ring.zero`, so a `ring.system` line in
  `binds.conf` needs the new name; `alt+0` is unchanged.
- A new terminal starts where N0's shell is standing, so `cd` in `alt+0` and the next one you
  open is already there.
- `ctrl+c`, `ctrl+x` and `ctrl+v` are the system clipboard, so a copy crosses between oket and
  anything else you have open.
- In a session `ctrl+c` copies too, and the interrupt moved to `ctrl+shift+c`. Both are rows:
  swap them back in `binds.conf` under `[terminal]`.
- `ctrl+k`, `ctrl+shift+k` and `ctrl+u` kill to the clipboard; `ctrl+shift+v` walks back through
  what you killed.
- A copy made with several carets pastes one piece per caret.
- Every caret is drawn, not just the one the gutter follows. A trail you dropped is a trail you
  can see.
- A start writes every setting into `config.conf`, commented out with its default, so the file
  says what there is to change. `[mouse] wheel` and `[mouse] double` are new; `[menu] palette`
  was always there and had nowhere to be read about.
- `:find <text>` selects every match at once, so typing over them replaces them all. `f3` and
  `shift+f3` step through them one at a time instead.
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
