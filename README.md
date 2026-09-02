# oket

Graphical text editing kernel, .so plugins. One visible surface at a time.

Everything on screen is a document: a file, a directory listing, a shell session, the command
line. A document is text plus a descriptor — data the kernel reads to decide how to draw it and
where a keystroke goes. The kernel owns the renderer, the viewport, the cursors, undo and the
bind table. Plugins produce documents. They never draw.

## The ring

One lane per kind of document, each numbered. `alt+1`..`alt+9` address slots in the lane you
are looking at, so three files and three listings are both on `alt+1..3`.

| | |
|---|---|
| `alt+f` `alt+t` `alt+e` | files, terminal, editor |
| `alt+0` | N0, where a command's output lands |
| ``alt+` `` | back to where you just were, across lanes |
| `alt+q` | close this slot; its number is never reused while others live |

A listing draws its rows through the same renderer a file does, and `enter` opens the one you
are standing on. `alt+t` is a real PTY: scrollback and the live grid are the document's lines,
so the kernel's own scroll, drag-select and `ctrl+shift+c` work on it with no terminal-specific
code behind them.

## The command line

`alt+c` opens it, `alt+;` opens it with the `:` already typed. A bare line goes to the shell, a
leading `:` is a builtin, `&&` chains them and "|" works via bash. Shell steps run in a session you can see and
answer.

```
:open src/oket/app.odin 3     # into slot 3 of the editor's lane
make && :ls
:sel | sort -u | :put         # the selection, out through a pipeline, back at point
```

`|` between two shell steps is bash's own — the chain hands it over whole. The two ends are
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

## Plugins

One `.so`, `dlopen`'d in-process, trusted. The seam is six messages — `register`, `submit`,
`reveal`, `event`, `open`, `close` — and reads are not among them: a plugin walks a document's
snapshot by pointer, with no lock and no call back into the kernel, and writes by submitting a
batch against the generation it read.

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

## Editing

The editor is a plugin, and the kernel has no text kind of its own. `:open` on a regular file
hands the path to whoever registered the `edit` kind.

```sh
:plug load edit
:open src/oket/app.odin
```

It owns what is genuinely an editor's: reading the file, `:w`, what a typed rune means, and the
verbs that are policy rather than storage — a newline that keeps the indent, a Tab that lands
on the next stop. Motion, selection, the viewport, undo and the plain delete verbs are the
kernel's, for every document. Swap in your own by registering the same kind.

## Build

```sh
./download-deps.sh     # once: libvterm, glfw, stb, tree-sitter into vendor/
./release.sh --local   # builds into build/

odin test src/tests -define:GLFW_SHARED=false
```

Needs Odin and Zig. `zig cc` builds the vendored C and the plugins.

## Licence

GPLv3 or later; see `LICENSE`. Third-party notices are in `NOTICE`.
