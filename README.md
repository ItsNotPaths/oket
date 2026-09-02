# oket

A document kernel. Odin, native plugins, one visible surface at a time.

**Everything is a document. A descriptor says how it behaves.**
**Reads are memory. Writes are transactions.**

One renderer, owned by the kernel. Plugins never draw.

## Status

Stage 7 of 13. The kernel opens a window, keeps a store of documents, and draws one of them
through its descriptor. Input funnels through one bind table that answers for keys and clicks
alike. There is a numbered ring per document kind, a command line, and command chains: a chord
can run a shell pipeline over the file under the pointer with no plugin and no build.

`alt+t` opens a terminal session. A session is a document like any other: its scrollback and
live grid are its lines, so the kernel's own viewport scrolls it, a drag selects it and
`ctrl+shift+c` copies. Colour arrives as style runs the renderer paints. The command line runs
its shell steps in that same kind of session, so a command that asks a question is one you can
answer.

Plugins are `.so` files, `dlopen`'d in-process. The seam is six messages, and reads are not
among them: a plugin walks a snapshot by pointer. It registers kinds, commands and bind
requests; it produces a document and a descriptor, and the kernel's one renderer draws it.
Every registration goes in a ledger, and unloading walks it backwards. The helper library is
linked into each plugin with LTO, so a helper inlines into your loop and the half you never
call is stripped.

```sh
./plugins/stage.sh plugins/hello build/plugins   # or `:pluginify plugins/hello`
```

No editing by keystroke yet — that is stage 8, where the editor arrives as a plugin with no
privileged path, and where the seam either holds or gets redesigned.

Oket supersedes `../okette`, which works and is kept beside this tree as the source of the
salvage. The reasoning behind the split, the build order and the open questions are in
`docs/PLAN.md`, which is not tracked.

## Build

```sh
./download-deps.sh     # once: libvterm, glfw, stb, tree-sitter into vendor/
./release.sh --local   # builds into build/

odin test src/tests -define:GLFW_SHARED=false
```

Needs Odin and Zig. `mise install` gets both. `zig cc` builds the vendored C and the plugins.

## Licence

GPLv3 or later; see `LICENSE`. Third-party notices are in `NOTICE`.
