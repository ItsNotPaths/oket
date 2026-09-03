# oket

Graphical text editing kernel, .so plugins. A strip of panels you scroll, one full-width by
default.

Everything on screen is a document: a file, a directory listing, a shell session, the command
line. A document is text plus a descriptor, data the kernel reads to decide how to draw it and
where a keystroke goes. The kernel owns the renderer, the viewport, the cursors, undo and the
bind table. Plugins produce documents. They never draw.

## The ring

One lane per kind of document, each numbered. `alt+1`..`alt+9` address slots in the lane you
are looking at, so three files and three listings are both on `alt+1..3`.

| | |
|---|---|
| `alt+f` `alt+t` `alt+e` | files, terminal, editor |
| `alt+.` | any other lane: the command line, with `:ring ` already typed |
| `alt+0` | N0, where a command's output lands |
| ``alt+` `` | back to where you just were, across lanes |
| `alt+q` | close this slot; its number is never reused while others live |

`alt+f` is the file browser. It is a plugin, the same way the editor is — the kernel opens no
listing of its own, and `:open` on a directory reports if nothing registers the `files` kind.
And it is a document like any other: `ls -la` output you can type into.

```
drwxr-xr-x      4096  Sep  2 21:35  ../
drwxr-xr-x       160  Sep  3 03:54  plugins/
-rw-r--r--     28914  Sep  3 03:54  README.md
```

`../` is row one of every listing, and it is a link like any other row — `enter` over it goes up.
Which directory you are in is the bar's answer; what a listing carries is the way out of it.

The caret is pinned to the end of a name, so every row you arrive on is ready to rename. `up`
and `down` move a row and land there; `enter` visits the row (a directory replaces the buffer, a
file goes to the editor); `right` goes into the directory under point and `left` comes back out
to the row it came from. Nothing moves the caret sideways, which is what frees the side arrows
to be the hierarchy. Typing and backspace are clamped into the name, so the mode bits, the size
and the date cannot be edited whatever the caret is doing. `ctrl+s` does the renames on disk and
says how many, `f5` reads the directory again and drops what you typed, `ctrl+b` shows dotfiles.
Undo is the kernel's, so `ctrl+z` works on a half-typed name like anywhere else.

`alt+t` is a real PTY: scrollback and the live grid are the document's lines, so the kernel's
own scroll, drag-select and `ctrl+shift+c` work on it with no terminal-specific code behind
them.

## The strip

Two files side by side is one oket, not two. A panel is a window onto the ring — the store, the
bind table, the plugin ledger and the io thread all stay single, so a link can cross from one
panel to the next. The layout is a horizontal strip you scroll, no nesting.

| | |
|---|---|
| `alt+left` `alt+right` | walk the strip |
| `alt+p` | a panel to the right of this one, standing on nothing |
| `alt+shift+p` | close the panel; what was in it stays in the ring |
| `alt+w` | full width or half width, which is the whole sizing model |

The two numberings do not interfere. A ring slot is per kind, stable and keeps its gaps; a panel
is positional, so closing one renumbers the strip and no document at all. `alt+N` addresses slot
N of the FOCUSED panel's lane, and the focused panel is the one with the caret in it — which is
also what makes a mixed strip legal: one browser and two editors, three panels, one lane each.

A slot is in at most one panel, because the viewport lives on the slot. Asking for a slot another
panel is standing on swaps the two.

One grammar addresses both. `#N` is a ring slot, `@N` is a panel counted from the left, `@+N` and
`@-N` are panels either side of the one you are in, and a bare `N` still means `#N`. A command
takes one of each, in any order, and names a panel the strip does not have yet by making it.

```
# slot 3 of the editor's lane, in the second panel
:open src/oket/app.odin #3 @2
# in the panel to the left, made if there is none
:open src/oket/ring.odin @-1
```

```
# config.conf, beside the binary
[strip]
gap = 8      # pixels between two panels
```

### Opening into another panel

`ctrl+enter` on a link opens it one panel to the left. To choose the panel instead, hold `tab`,
press `enter`, steer with the side arrows and let `tab` go: the caret shows where the thing will
land, and `esc` drops the whole gesture.

Both are ordinary rows, and `tab+enter` is a different chord from `tab`, so an editor keeps its
indent.

```conf
[surface]
ctrl+enter = exec :open <path> @-1
tab+enter  = pick :open <path> @
```

## The command line

`alt+c` opens it, `alt+;` opens it with the `:` already typed, `alt+.` with `:ring `. A bare line goes to the shell, a
leading `:` is a builtin, `&&` chains them and "|" works via bash. Shell steps run in a session you can see and
answer.

```
# into slot 3 of the editor's lane
:open src/oket/app.odin #3
make && :ls
# the selection, out through a pipeline, back at point
:sel | sort -u | :put
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

A value is a verb's name, or `exec`/`stage`/`pick` and a command line. `exec` runs the line,
`stage` puts it in the command line for aiming, and `pick` expands it now and runs it when the
chord's held key comes up. `<name>` holes fill from the fields of the line under point, so a
bind acts on document data with no callback into the plugin that drew it. A click is a chord
like any other, and hovering underlines the field a bound click would act on. `f1` then any
chord says what it does and where it was bound.

A field is a named span of a line, and it may carry a VALUE that is not the text it covers.
That is what makes a row a link: the tree draws `browser.c` and `<path>` hands on
`plugins/browser/browser.c`, so a row can be renamed by typing without what it points at moving.

Chains do the branching a callback would. The file browser's `enter` is one row:

```conf
[files]
enter = exec :br.enter <path> && :open <path>
```

`br.enter` visits a directory and stops the chain; over a file it does nothing, and `&&` carries
on to the kernel's `:open`, which hands the path to the editor. The plugin's whole contribution
is an exit code.

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

`plugins/syntax` is a tree-sitter plugin that draws nothing. It asks to be told about every
document, picks a grammar off the file's extension, and publishes what its highlights query
captures. A parse too big for one frame says so and resumes on the next, so a megabyte colours
from the top down without a dropped frame and without a thread.

Grammars are not shipped, and the list of the ones you could have is a document:

```sh
:ring grammars   # alt+g
```

Three hundred languages, one per row, a `*` on the ones already built. Typing filters, by name
or by an extension you have open — `rs` finds `rust`. `enter` builds the row under point, and
the row is the whole of the install:

```conf
[grammars]
enter = exec :gr.build <lang> && oket-grammar <lang> <repo> <rev> <sub> || true && :grammar ready <lang>
```

Four holes over one row, a shell step you can watch in N#, and a plugin command either side of
it. The list spawns nothing and knows nothing about git. `oket-grammar` ships beside `oket`, so
it is on `PATH` wherever oket is, and it takes a directory as well as a URL — which is how a
checkout you already have gets built, and how the tests build one with no network.

The two plugin commands are the feedback. `:gr.build` marks the row and starts a bar on it, so a
clone and a compile are not a frozen list:

```text
  rust             ░░░░░░░░░██████░░░░░░░░  building 4s
```

One lit run crosses in 1.26 s and the seconds count up. Both move on a monotonic clock, not on
frames: the loop polls rather than waits while anything is latched, so a frame count would run
the bar at whatever the display and the GPU allow. Nothing here can measure a clone, so nothing
fills — the seconds are the only real number on the row, and they are what says a build is slow
rather than hung.

`:grammar ready` is the other end, and the shell step is `|| true` so that it always runs. It
stats `<lang>.so` and the row stops on what is there: `done` beside a fresh `*`, or `failed`
with the reason already in N#. A refusal comes early — a name the registry does not carry, or a
build already out, stops the chain at the first step rather than four steps later.

The grammar lands in `grammars/` beside the binary as `<name>.so` plus its `<name>.scm` query,
and an open file takes its colours on the next frame. `:grammar status` counts what is installed
and says where it is looking; `:grammar dir <path>` moves it.

The name is what an extension selects: `.rs` wants `rust`, `.json` wants `json`, and the registry
the list is built on answers that too, so a row you install and a file you open cannot disagree.
A language nobody listed still works as soon as its grammar is built under the name of its own
extension.

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

## Crashes, and the start after one

Every document that is a file and takes typing is journaled: each splice is appended to a file
of its own as it lands, so what recovery reads is bytes that were already on the platter and
never in-memory state a crash is entitled to have corrupted. `kill -9` mid-edit, start again,
and the work is offered back.

```
oket dev

unsaved work a crash left behind — enter takes it back:
  /home/you/notes.md   6 edit(s)
  (:recover drop <path> throws one away)
```

That page is a document like any other, so `enter` over a row is one bind over one field, and
a start with nothing to report never shows it — `:home` asks for it whenever you want it. A journal whose replay matches the file is
dropped without asking: the work was saved before the crash. A clean exit removes its journals,
because quitting is a decision and a crash is not.

A plugin that dies where the fault net cannot unwind takes the process with it. The handler
writes down its name — one `write`, to a descriptor opened while the process was still healthy —
and the next start reads that, holds the plugin back and says so. `:plug load <name>` takes it
again, which is you saying it is fixed. `--no-plugins` starts with none of them; `--safe` is
that plus ignoring the session, for the start where what breaks you is the file the last one
reopened.

The ring can persist across restarts, off unless you ask:

```
# config.conf, beside the binary
[session]
restore = on
```

A session is a list of command lines, so restoring one is running them and there is nothing to
version. A document with no file is not written down: a terminal's session ended with the
process.

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
