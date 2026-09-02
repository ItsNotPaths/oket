# oket

A document kernel. Odin, native plugins, one visible surface at a time.

**Everything is a document. A descriptor says how it behaves.**
**Reads are memory. Writes are transactions.**

One renderer, owned by the kernel. Plugins never draw.

## Status

Stage 6 of 13. The kernel opens a window, keeps a store of documents, and draws one of them
through its descriptor. Input funnels through one bind table that answers for keys and clicks
alike. There is a numbered ring per document kind, a command line, and command chains: a chord
can run a shell pipeline over the file under the pointer with no plugin and no build.

`alt+t` opens a terminal session. A session is a document like any other: its scrollback and
live grid are its lines, so the kernel's own viewport scrolls it, a drag selects it and
`ctrl+shift+c` copies. Colour arrives as style runs the renderer paints. The command line runs
its shell steps in that same kind of session, so a command that asks a question is one you can
answer.

No plugins and no editing by keystroke yet — those are stages 7 and 8.

Oket supersedes `../okette`, which works and is kept beside this tree as the source of the
salvage. The reasoning behind the split, the build order and the open questions are in
`docs/PLAN.md`, which is not tracked.

## Build

```sh
./download-deps.sh     # once: libvterm, glfw, stb, tree-sitter into vendor/
./release.sh --local   # builds into build/

odin test src/tests -define:GLFW_SHARED=false
```

Needs Odin and Zig. `mise install` gets both. `zig cc` builds the vendored C and, later,
the plugins.

## Licence

GPLv3 or later; see `LICENSE`. Third-party notices are in `NOTICE`.
