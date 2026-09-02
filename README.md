# oket

A document kernel. Odin, native plugins, one visible surface at a time.

**Everything is a document. A descriptor says how it behaves.**
**Reads are memory. Writes are transactions.**

One renderer, owned by the kernel. Plugins never draw.

## Status

Design. Nothing is built yet. This tree holds the repo scaffold and the vendored patches;
`src/` arrives with stage 0.

Oket supersedes `../okette`, which works and is kept beside this tree as the source of the
salvage. The reasoning behind the split, the build order and the open questions are in
`docs/PLAN.md`, which is not tracked.

## Build

```sh
./download-deps.sh     # once: libvterm, glfw, stb, tree-sitter into vendor/
./release.sh --local   # builds into build/
```

Needs Odin and Zig. `mise install` gets both. `zig cc` builds the vendored C and, later,
the plugins.

## Licence

GPLv3 or later; see `LICENSE`. Third-party notices are in `NOTICE`.
