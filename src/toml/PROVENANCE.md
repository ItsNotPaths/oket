# src/toml — vendored

Upstream: https://github.com/Up05/toml_parser
Commit:   10aee3739d1a144efe79e95d8a094e9c1563bb03 (2026-05-25)
License:  MIT, see LICENSE. Copyright (c) 2024 Ult1.

Committed rather than fetched: it is plain Odin source with nothing to compile, and TOML
1.0.0 has been frozen since 2021, so there is little upstream to track.

## Local changes

Removed, because oket embeds the parser and never runs it as a tool:

| dropped | lines | why |
|---|---:|---|
| `main.odin` | 272 | CLI driver. Only user of `core:encoding/json`. |
| `unmarshal.odin` | 670 | Reflection-based struct filling. `get` covers our two files. |
| `dates/` | 326 | No oket setting is date-shaped; timestamps we write are quoted strings. |

2851 lines to 1545, and 18 KB off the binary. Dropping `dates/` also removed the
`dates.Date` variant of `Type`, `parse_date`, and the `get_date` accessors.

**Consequence:** a bare date literal is no longer valid input. `since = 2026-08-30T21:14:02Z`
fails with `Parser_Is_Stuck` rather than parsing. It fails loudly, not as `2026`, but the
error does not say "dates are unsupported". Quote the value, or restore `dates/` from
upstream if a real date setting ever arrives.

## Notes

`parse_data` and `parse_file` take an allocator and thread it all the way down; nothing
escapes to `context.allocator`. Either wrap a parse in an arena or call `deep_delete`.
