# oket

A document kernel. Odin, native plugins, one visible surface at a time.

**Everything is a document. A descriptor says how it behaves.**
**Reads are memory. Writes are transactions.**

One renderer, owned by the kernel. Plugins never draw.

## Status

Stage 1 of 13. The salvaged packages are in `src/` with their tests green, and the kernel
opens a window and paints a cell grid. Nothing edits anything yet.

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
