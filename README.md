# oket

<img align="left" width="150" src="assets/oketpus.png" alt="oket">

A graphical text editing kernel with `.so` plugins.

emacs like, buffer/doc based, a panel is a document + descriptor. Documents sit in rings, one
numbered lane per kind, so `alt+1..9` reaches the third file and the third listing without
either knowing the other exists.

Panel displays are built in four layers, plugins write to each separately.

**The document** is the bytes. A piece table the kernel owns, in an arena a reader can hold
across a write. A plugin submits edits and never holds the text.

**The descriptor** is how one generation renders and routes: wrap, line numbers, columns,
per-line depth, the bind context a chord lands in, and named fields that turn a row into a
link. It is immutable and replaced whole per write, and it carries no colour at all. This is
effectively render params to the kernel.

**Spans** are the colour. A parser, a linter or a search publishes byte ranges carrying a style
token, into a bucket under its own name, on the same transaction as the text, so runs and the
bytes they cover land at one generation. A run says which channels it sets, foreground,
background or attributes, so an underline over a colour draws as both instead of replacing it.
A config line ranks the names, lowest first; a publisher the line does not name draws on top.

**View stages** are the post-processing, and they run at settle, not at draw. A stage is handed
a snapshot and returns edits against it, in the vocabulary `submit` already uses. A fold is a
deleted run, a ghost an insert, a popup a replace over the cells it covers. Each stage sees
what the last one returned.

Both orders are config, per kind, so every plugin-owned panel sets its own:

```conf
[plugin-name] layer = post-processing-plugin-1, post-processing-plugin-2
[edit] spans = syntax, lsp     # who colours over whom
[edit] view  = fold, example   # the pipeline, in order
```

Neither the spans nor the stages reach the file.

Linux, x86_64.

```sh
curl -fsSL https://github.com/ItsNotPaths/oket/releases/latest/download/install.sh | sh
```

Or unpack the tarball and run it. Nothing is touched until you `:oket install`.

| | |
|---|---|
| `:oket status` | the mode, and every path it chose |
| `:oket install` | put the files where they go, then restart |
| `:oket uninstall` | take them back out; settings, state and grammars stay |
| `:oket update` | fetch the latest release and install it, in N0; then restart |

Where a binary sits is where its files go. In a `bin` directory oket is installed and
uses the XDG folders. Anywhere else it is portable and everything lives beside it.

```
~/.local/bin/oket                                 the binary
~/.config/oket/config.conf                        what you edit
~/.local/share/oket/{plugins,themes,grammars}     what a release wrote
~/.local/state/oket/{journal,quarantine,session}  what a crash left
```

`oket <path>` opens it. `oket <dir>` is where the first terminal starts; every one after it
starts where N0's shell is standing.

## Getting around

| | |
|---|---|
| `alt+f` `alt+t` `alt+e` | files, terminal, editor |
| `alt+1`..`alt+9` | slot N of the lane you are in |
| `alt+0` | N0, the terminal oket runs things in, and where a command's output lands |
| hold `alt` | the lane drawn down the side of the panel, so the numbers are on screen |
| ``alt+` `` | back where you just were, across lanes |
| `alt+q` | close this slot, and the panel with it |
| `alt+c` | the command line; `alt+;` with `:` typed, `alt+.` with `:ring ` |
| `alt+space` | the menubar |
| `f1` then any chord | what it does, and where it was bound |

`alt+f` is the file browser, a plugin like the editor. `up`/`down` move a row, `enter` visits
it, `ctrl+backspace` and the `..` row go back up. The caret sits at the end of each name, so any
row you land on is ready to rename; `ctrl+s` does the renames, `f5` re-reads, `ctrl+b` shows
dotfiles. The side arrows stay the kernel's own motion, walking the name you are editing.

`alt+t` is a real PTY. Scrollback and the live grid are the document's lines, so scrolling and
drag-select are the kernel's own, with no terminal-specific code behind them. **`ctrl+c` copies
there too.** One chord, one meaning, in every document. The interrupt is `ctrl+shift+c`. Both
are ordinary rows, so a `binds.conf` that swaps them back is two lines.

A new session starts where N0's shell is standing, so `cd` in `alt+0` and the next terminal you
open is already there.

Holding `alt` draws the lane you are in down the side of the panel — its number and its title,
one row each, with the slot you are standing in filled. Gaps stay gaps, because the column has to
read the way the key does. `[switcher] show = numbers` in `config.conf` cuts it back to the
digits alone.

## Panels

| | |
|---|---|
| `alt+left` `alt+right` | walk the strip |
| `alt+shift+left` `alt+shift+right` | move this panel along it |
| `alt+p` / `alt+shift+p` | new panel / close it |
| `alt+w` | next width in its list; `:width 30 50 100` |
| | `full` `half` `third` `quarter` are the same numbers in words |
| `ctrl+enter` | open a link one panel left |
| hold `tab`, `enter` | aim, steer with the arrows, release to drop it |

Two files side by side is one oket, not two: the store, the bind table and the plugin ledger
stay single, so a link can cross panels.

A percent near an exact fraction becomes it. `:width 30` is a third, so three of them fill the
strip instead of leaving a tenth of it empty.

One grammar addresses both numberings. `#N` is a ring slot, `@N` a panel from the left, `@+N`
and `@-N` either side of you, `@=` the panel already showing it.

```
:open src/oket/app.odin #3 @2
:open src/oket/ring.odin @-1     # made if there is none
```

One path is one document. Open a file the ring already holds and you land where it is, not on a
second copy of it.

## The command line

A bare line goes to the shell, `:` is a builtin, `&&` chains them. Shell steps run in a session
you can see and answer.

```
make && :ls
:sel | sort -u | :put                 # selection out through a pipeline, back at point
:find thing && echo replaced | :put   # select all "thing"s, echo "replaced" and put it in selections
```

## Binds

```conf
# binds.conf, beside config.conf
[files]
enter       = exec :open <path>
right-click = stage :open <path>

[global]
alt+g         = exec git diff -- <path> | :put
ctrl+b ctrl+f = exec :ring files
```

A section is a context or a kind. A value is a verb's name, or `exec`/`stage`/`pick` and a
command line. `<name>` holes fill from the fields of the line under point, so a bind acts on
document data with no callback. A click is a chord like any other.

Two-chord binds work, and both chords carry a modifier. That is what keeps a primer
transparent: an unmodified key after one clears it and does what it always did.

## Config

```conf
# config.conf, generated with every setting commented out
[strip]   gap = 4        # pixels between panels
[cursor]  select = 90    # percent of the swap a selection carries
[session] restore = on   # the ring, across restarts
[switcher] show = titles # what a held alt draws: titles or numbers
[edit]    spans = syntax, lsp     # who colours over whom, lowest first
[edit]    view  = fold, example   # the view pipeline, in order
[menu]    bar   = file, edit, view, panel
```

Themes are helix's TOML, dropped in unchanged.

## Editing

| | |
|---|---|
| `ctrl+alt+up` `ctrl+alt+down` | another caret above / below |
| `alt+d` / `alt+shift+d` | the word under the caret, one match / every match |
| `alt+click` | a caret there; plain click puts them all down |
| `alt+z` / `alt+shift+z` | fold the block point is in / unfold every one |
| `alt+/` | complete from words in the buffer; again for the next |
| `esc` | put the carets down |

Carets are placed, not armed. No prefix key, no mode. The editor is a plugin; motion,
selection, undo and the viewport are the kernel's, for every document.

## Syntax

`alt+g` lists three hundred grammars, a `*` on the ones you have. Type to filter, `enter`
builds the row under point. Nothing is shipped and nothing is fetched at startup.

```conf
[grammars]
enter = exec :gr.build <lang> && oket-grammar <lang> <repo> <rev> <sub> || true && :grammar ready <lang>
```

Spans are stored per document and per publisher, so who draws over whom is a config line rather
than load order. A run says which of foreground, background and attributes it sets; what it
leaves alone shows through from below. A parse too big for one frame says so and resumes on the
next.

## Plugins

One `.so`, `dlopen`'d in-process. The seam is six messages: `register`, `submit`, `reveal`,
`event`, `open`, `close`. Reads are not among them. A plugin walks a snapshot by pointer with no
lock, and writes by submitting a batch against the generation it read.

```c
#include "oket_helpers.h"

OKET_MAIN {
    static const oket_kind_spec SPEC = {"notes", 5, "text", 4, {open_note, close_note, event}};
    NOTES = api->register_kind(api, self, &SPEC);
    api->register_command(api, self, "note", 4, "start one", 9, note_cmd);
    api->request_bind(api, self, "global", 6, "alt+n", 5, "exec :note", 10);
    return 0;
}
```

```sh
./plugins/stage.sh plugins/example build/plugins # or `:pluginify plugins/example` while it runs
```

A chord is requested: the row lands in `binds.conf` and the file decides after
that. Slow work is a kernel job, not a plugin thread — `io_spawn` and `io_watch` come back as
ordinary events on the main thread.

Every `.so` in `plugins/` loads at startup. One that faults is unloaded where it stands and
named in the bar. `--no-plugins` starts with none.

## Crashes

Every file you type into is journaled as it lands, so recovery reads bytes that were already on
the platter. `kill -9` mid-edit, start again, and the work is offered back on the home page.

A plugin that takes the process down is named by the fault handler and held back at the next
start. `:plug load <name>` says you fixed it. `--safe` is `--no-plugins` plus ignoring the
session.

## Build

```sh
./download-deps.sh               # once: libvterm, glfw, stb, tree-sitter into vendor/
./release.sh --local             # into build/
./release.sh --local --asan      # kernel and plugins under AddressSanitizer
./release.sh --local --tarball   # and pack it into dist/

odin test src/tests -define:GLFW_SHARED=false
```

Needs Odin and Zig; `zig cc` builds the vendored C and the plugins. `build/oket` is portable, so
it keeps its own config and journal and never touches an installed copy's.

Write plugins against the ASan build: a wild write is caught at the write, with a stack trace,
instead of at the crash four frames later inside kernel code.

## Special thanks

**Ryan Fleury** and **[RAD Debugger](https://github.com/EpicGamesExt/raddebugger)**, for performant
diff based doc editing and installation sequence.

**[Helix](https://helix-editor.com/)**, `languages.toml` and theme format.

## Licence

GPLv3 or later; see `LICENSE`. Third-party notices are in `NOTICE`.
