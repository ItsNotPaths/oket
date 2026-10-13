# oket

<img align="left" width="150" src="assets/oketpus.png" alt="oket">

A graphical text editing kernel with `.so` plugins.

Linux, x86_64.

```sh
curl -fsSL https://github.com/ItsNotPaths/oket/releases/latest/download/install.sh | sh
```

Emacs-like and document based: a panel shows a document and a descriptor. Documents sit in
rings, one numbered lane per kind, so `alt+3` reaches the third file or the third listing.

The kernel is [lues](https://github.com/ItsNotPaths/lues). oket adds three layers over each
document, and plugins write:

- **descriptors** say how a document draws and routes: wrap, line numbers, columns, depth,
  bind context, and fields that turn a row into a link.
- **spans** are colour. Each publisher has its own bucket, and its runs land with the text
  they cover.
- **view stages** derive what is drawn, as edits against a snapshot: a fold, a ghost, a popup.

Both orders are config, per kind:

```conf
[edit] spans = syntax, lsp     # who colours over whom, lowest first
[edit] view  = fold, example   # the pipeline, in order
```

None of this reaches the file.

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

`alt+space` opens the menubar. Every command and bind is listed there, under the plugin or
context that owns it, so explore it in the app. `f1` and then a chord says what the chord does
and where it was bound.

Two chords are not what you expect. In the terminal, `ctrl+c` copies, the same as in every
document; the interrupt is `ctrl+shift+c`. `alt+0` is N0, the terminal oket runs things in.

## Panels

Two files side by side is one oket, so a link can cross panels. One grammar addresses ring slots
and panels: `#N` is a ring slot, `@N` a panel from the left, `@+N` and `@-N` either side of you,
`@=` the panel already showing it.

```
:open src/oket/app.odin #3 @2
:open src/oket/ring.odin @-1     # made if there is none
```

One path is one document. Open a file the ring already holds and you land where it is.

## The command line

A bare line goes to the shell, `:` is a builtin, `&&` chains them. Shell steps run in a session
you can see and answer.

```
make && :ls
:sel | sort -u | :put                 # selection out through a pipeline, back at point
:find thing && printf replaced | :put # select all "thing"s, then put "replaced" in each
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
[menu]    bar   = file, edit, view, panel
```

Themes are helix's TOML, dropped in unchanged.

## Syntax

`alt+g` lists three hundred grammars, a `*` on the ones you have. Type to filter, `enter`
builds the row under point. Nothing is shipped and nothing is fetched at startup.

## Plugins

A plugin is a [lues](https://github.com/ItsNotPaths/lues) plugin: one `.so` that exports
`lues_main`. lues's calls come first in the api, and oket's follow them (`describe`, `cursors`,
`reveal`, `register_view`, `world`). `oket_side_of(snap)` gives oket's view of a snapshot: the
descriptor, the carets and the folds.

```c
#include "oket_helpers.h"

LUES_MAIN {
    static const lues_kind_spec SPEC = {sizeof SPEC, "notes", 5, "text", 4,
                                        {open_note, close_note, event}};
    NOTES = api->register_kind(api, self, &SPEC);
    api->register_command(api, self, "note", 4, "start one", 9, note_cmd);
    api->request_bind(api, self, "global", 6, "alt+n", 5, "exec :note", 10);
    return 0;
}
```

```sh
./plugins/stage.sh plugins/example build/plugins # or `:pluginify plugins/example` while it runs
```

A plugin asks for a chord, and the row lands in `binds.conf`; the file decides after that. Every
`.so` in `plugins/` loads at startup. `--no-plugins` starts with none.

A repro is a file. `:harness repro.oks plugins/notes` runs it in a second oket with no window
and no fault net, so a crash drops a core. A line is a command, a chord (`> ctrl+shift+k`), text
to type, or a check (`! lines == 12`) that waits for its answer.

## Crashes

Every file you type into is journaled as it lands, so recovery reads bytes that were already on
the platter. `kill -9` mid-edit, start again, and the work is offered back on the home page.

A plugin that faults is unloaded and named in the bar. One that takes the process down is held
back at the next start; `:plug load <name>` says you fixed it. `--safe` is `--no-plugins` plus
ignoring the session.

## Build

```sh
./download-deps.sh               # lues, libvterm, sdl3, stb, tree-sitter into vendor/; again after a LUES_REV bump
./release.sh --local             # into build/
./release.sh --local --asan      # kernel and plugins under AddressSanitizer
./release.sh --local --tarball   # and pack it into dist/

odin test src/tests -collection:lues=vendor/lues/src -extra-linker-flags:"-Lvendor/sdl3"
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
