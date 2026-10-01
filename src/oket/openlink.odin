package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "lues:pt"
import "../desc"
import "../store"
import "../txt"

// `:openlink`: what a link is FOR, decided once and here. A plugin says WHERE a link is by
// publishing a `link` data span whose value is the target; this reads the target and does the
// one thing a target can mean. A URI goes to `[openlink] browser`; a path that exists, with an
// optional `:line[:col]`, opens in the ring with the caret there. Anything else is not a link,
// and the word under point is selected instead — so one double-click row serves text and links.

// The data key a link rides under. The kernel's own, because this verb reads it.
LINK_KEY :: "link"

BROWSER_DEFAULT :: "${BROWSER:-xdg-open}"

USAGE_OPENLINK :: ":openlink [<target>]"

@(private = "file")
Link :: enum {
    None,
    Uri,
    Path,
}

builtin_openlink :: proc(a: ^App, args: string, _: CL_Step) -> bool {
    _, target := first_arg(strings.trim_space(args))
    if target == "" {
        target = link_under(a)
    }
    kind, path, line, col := link_parse(a, target)
    switch kind {
    case .Uri:
        return link_browse(a, target)
    case .Path:
        return link_open(a, path, line, col)
    case .None:
    }
    select_expand(a)
    return true
}

// The `link` span the caret is on, by the rule every hole fills by (desc.field_under).
@(private = "file")
link_under :: proc(a: ^App) -> string {
    s := active(a)
    snap, d, ok := reading(a, s)
    if !ok {
        return ""
    }
    defer pt.snapshot_release(snap)
    defer desc.release(d)
    at := s.view.point.head
    f, _ := desc.field_under(doc_fields(a, s.doc, &snap.text, at.line, at.line + 1), at.line,
                             at.col, LINK_KEY)
    return f.value
}

// A URI has a scheme and `//`, or is `mailto:`. A path is one that exists, relative to the
// focused document's directory first and the start's directory second; `:line` and `:col` come
// off its end, 1-based as compilers print them, and 0 when absent.
@(private = "file")
link_parse :: proc(a: ^App, target: string) -> (kind: Link, path: string, line, col: int) {
    if target == "" {
        return
    }
    if uri_like(target) {
        return .Uri, "", 0, 0
    }
    path, line, col = split_position(target)
    if strings.has_prefix(path, "~/") {
        path, _ = filepath.join({os.get_env("HOME", context.temp_allocator), path[2:]},
                                context.temp_allocator)
    }
    for dir in ([2]string{link_dir(a), a.dir}) {
        full := path
        if !filepath.is_abs(path) && dir != "" {
            full, _ = filepath.join({dir, path}, context.temp_allocator)
        }
        if os.exists(full) {
            return .Path, full, line, col
        }
    }
    return
}

@(private = "file")
uri_like :: proc(s: string) -> bool {
    if strings.has_prefix(s, "mailto:") {
        return true
    }
    scheme, _, found := strings.partition(s, "://")
    if found == "" || scheme == "" {
        return false
    }
    for c, i in scheme {
        ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
              i > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.')
        if !ok {
            return false
        }
    }
    return true
}

// `x.c:12:4` is `x.c`, 12, 4. A trailing part that is not a number stays in the path.
@(private = "file")
split_position :: proc(s: string) -> (path: string, line, col: int) {
    path = s
    nums: [2]int
    n := 0
    for n < 2 {
        i := strings.last_index_byte(path, ':')
        if i < 0 {
            break
        }
        v, ok := strconv.parse_int(path[i + 1:], 10)
        if !ok || v < 1 {
            break
        }
        nums[n] = v
        n += 1
        path = path[:i]
    }
    switch n {
    case 1:
        line = nums[0]
    case 2:
        line, col = nums[1], nums[0]
    }
    return
}

// The focused document's directory, when it is a file.
@(private = "file")
link_dir :: proc(a: ^App) -> string {
    s := active(a)
    if s == nil {
        return ""
    }
    d := store.store_descriptor(a.docs, s.doc)
    if d == nil {
        return ""
    }
    defer desc.release(d)
    return d.file != "" ? strings.clone(filepath.dir(d.file), context.temp_allocator) : ""
}

// After the chain, as a shell step, so the browser's own output lands in N# like any command's.
@(private = "file")
link_browse :: proc(a: ^App, uri: string) -> bool {
    if len(a.queue) >= QUEUE_MAX {
        message_set(a, ":openlink: the queue is full")
        return false
    }
    browser := a.config.browser != "" ? a.config.browser : BROWSER_DEFAULT
    append(&a.queue, fmt.aprintf("%s %s", browser, sh_arg(uri)))
    return true
}

@(private = "file")
link_open :: proc(a: ^App, path: string, line, col: int) -> bool {
    if !builtin_open(a, sh_arg(path), {}) {
        return false
    }
    s := active(a)
    doc := s != nil ? store.store_doc(a.docs, s.doc) : nil
    if doc == nil || line == 0 {
        return true
    }
    at := txt.Pos{min(line - 1, max(txt.doc_line_count(doc) - 1, 0)), max(col - 1, 0)}
    at.col = min(at.col, txt.doc_line_len(doc, at.line))
    txt.doc_reset_cursor(doc, at)
    point_sync(a)
    off := txt.doc_off(doc, at)
    reveal_span(a, s.doc, off, off, .Center)
    return true
}
