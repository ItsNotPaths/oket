# oket

Graphical text editing kernel, .so plugins. One visible surface at a time.

Everything on screen is a document: a file, a directory listing, a shell session, the command
line. A document is text plus a descriptor, data the kernel reads to decide how to draw it and
where a keystroke goes. The kernel owns the renderer, the viewport, the cursors, undo and the
bind table. Plugins produce documents. They never draw.

## The ring

One lane per kind of document, each numbered. `alt+1`..`alt+9` address slots in the lane you
are looking at, so three files and three listings are both on `alt+1..3`.

| | |
|---|---|
| `alt+f` `alt+t` `alt+e` `alt+b` | files, terminal, editor, tree |
| `alt+0` | N0, where a command's output lands |
| ``alt+` `` | back to where you just were, across lanes |
| `alt+q` | close this slot; its number is never reused while others live |

A listing draws its rows through the same renderer a file does, and `enter` opens the one you
are standing on. `alt+b` is the file tree, a plugin that produces indented rows and no more:
the indent is one number per line and the kernel draws it. `alt+t` is a real PTY: scrollback and
the live grid are the document's lines, so the kernel's own scroll, drag-select and
`ctrl+shift+c` work on it with no terminal-specific code behind them.

## The command line

`alt+c` opens it, `alt+;` opens it with the `:` already typed. A bare line goes to the shell, a
leading `:` is a builtin, `&&` chains them and "|" works via bash. Shell steps run in a session you can see and
answer.

```
:open src/oket/app.odin 3     # into slot 3 of the editor's lane
make && :ls
:sel | sort -u | :put         # the selection, out through a pipeline, back at point
```

`|` between two shell steps is bash's own, the chain hands it over whole. The two ends are
ours: `:sel` puts the selection on the next step's stdin, `:put` replaces it with what came
back.

## Binds

`binds.conf` sits beside the binary. A section is a context or a kind's name, and the narrower
one wins where it applies.

```conf
[files]
enter       = exec :open <path>
right-click = stage :open <path>

[global]
alt+g = exec git diff -- <path> | :put
```

A value is a verb's name, or `exec`/`stage` and a command line. `<name>` holes fill from the
fields of the line under point, so a bind acts on document data with no callback into the
plugin that drew it. A click is a chord like any other, and hovering underlines the field a
bound click would act on. `f1` then any chord says what it does and where it was bound.

Chains do the branching a callback would. The file tree's `enter` is one row:

```conf
[browser]
enter = exec :br.toggle <path> && :open <path>
```

`br.toggle` expands a directory and stops the chain; over a file it does nothing, and `&&`
carries on to the kernel's `:open`, which hands the path to the editor. The plugin's whole
contribution is an exit code.

## Plugins

One `.so`, `dlopen`'d in-process, trusted. The seam is six messages: `register`, `submit`,
`reveal`, `event`, `open`, `close`. Reads are not among them: a plugin walks a document's
snapshot by pointer, with no lock and no call back into the kernel, and writes by submitting a
batch against the generation it read.

A plugin that draws nothing asks to be told about documents it did not open, and a handler that
answers "not finished" is called again next frame. That is the whole of how long work is spread
without a thread.

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

A chord is never claimed, only requested: the row lands in `binds.conf` and the file decides
from then on. Every registration goes in a ledger, and unloading walks it backwards.

```sh
./plugins/stage.sh plugins/hello build/plugins   # or `:pluginify plugins/hello` while it runs
```

That one step compiles the helper library in with `-flto`, so a snapshot walk inlines into your
loop and the half you never call is stripped. `:plug load|unload|reload <name>` does the rest.

Every `.so` in `plugins/` loads at startup. One that faults, or stops returning, is unloaded
where it stands and named in the bar: the kernel keeps its documents and carries on drawing
them. `oket --no-plugins` starts with none of them, for the day that is not enough.

## Syntax

Colour is a span layer: a byte range with a style token on it, stored per document and per
publisher. A parser, a linter and a search each write their own layer, the kernel merges them in
one fixed order, and the renderer paints the answer. Nothing that publishes colour knows what a
theme is — it names a token, and the palette decides.

`plugins/syntax` is a tree-sitter plugin that draws nothing and opens nothing. It asks to be
told about every document, picks a grammar off the file's extension, and publishes what its
highlights query captures. A parse too big for one frame says so and resumes on the next, so a
megabyte colours from the top down without a dropped frame and without a thread.

Grammars are not shipped. Building one is a shell script, and reaching it is a command line:

```sh
:oket-grammar rust https://github.com/tree-sitter/tree-sitter-rust && :grammar ready rust
```

A shell step and a plugin command, chained — the seam grows nothing for it. `oket-grammar` ships
beside `oket`, so it is on `PATH` wherever oket is. The grammar lands in `grammars/` beside the
binary as `<name>.so` plus its `<name>.scm` query, and an open file takes its colours on the next
frame. `:grammar status` says where it is looking; `:grammar dir <path>` moves it. Point it at a
directory instead of a URL to build a checkout you already have.

The name is what an extension selects, and the extension IS the name unless the plugin knows
better: `.rs` wants `rust`, `.json` wants `json`. A language nobody listed works as soon as its
grammar is built under the name of its own extension.

## Subprocesses and watched files

Slow work is a kernel job, not a plugin thread. A plugin asks for a child process or a watched
path, and the answer arrives as an ordinary event on the main thread:

```c
oket_io server = api->io_spawn(api, self, doc, argv, nargv, NULL, 0);
api->io_write(api, self, server, request, len);   /* queued; a full pipe blocks nobody */
oket_io w = api->io_watch(api, self, doc, path, path_len);
```

One kernel thread does the waiting for every plugin — one `poll` over every child's pipes and
one inotify descriptor — and a frame's worth of output is handed over at the same point in the
frame every other write lands at. A language server, a formatter, a linter and a file watch all
ride that, and none of them is a thread a plugin can see. The child's stderr is inherited rather
than captured: merging it into stdout would corrupt a framed protocol, and a shell redirect
already captures it.

A watch names a file and holds its DIRECTORY, so a save by rename is reported rather than
missed — which is how most programs write a file.

## Editing

The editor is a plugin, and the kernel has no text kind of its own. `:open` on a regular file
hands the path to whoever registered the `edit` kind, which is a plugin like any other and
loads at startup like any other.

```sh
:open src/oket/app.odin
```

It owns what is genuinely an editor's: reading the file, `:w`, what a typed rune means, and the
verbs that are policy rather than storage, a newline that keeps the indent, a Tab that lands
on the next stop. It watches the file it opened, so a checkout or a formatter that rewrites it
underneath is taken back into the buffer — only the changed part, so the carets stay where they
were sitting, and only while you have no unsaved edits of your own. If you do, it says so and
changes nothing. Motion, selection, the viewport, undo and the plain delete verbs are the
kernel's, for every document. Swap in your own by registering the same kind.

## Build

```sh
./download-deps.sh          # once: libvterm, glfw, stb, tree-sitter into vendor/
./release.sh --local        # builds into build/
./release.sh --local --asan # the same, kernel and plugins under AddressSanitizer

odin test src/tests -define:GLFW_SHARED=false
```

Write a plugin against the ASan build. A wild write is caught at the write, with a stack trace,
instead of at the crash four frames later inside kernel code.

Needs Odin and Zig. `zig cc` builds the vendored C and the plugins.

## Licence

GPLv3 or later; see `LICENSE`. Third-party notices are in `NOTICE`.
