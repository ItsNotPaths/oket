#+build linux
package font

import "core:dynlib"
import "core:strings"
import "core:sync"

// fontconfig, dlopened rather than linked: a machine without it degrades instead of failing
// to start. It resolves the `monospace` alias per the user's own config and can search by
// codepoint, the two questions grab asks.

@(private = "file")
Fc :: struct {
    InitLoadConfigAndFonts: proc "c" () -> rawptr,
    NameParse:              proc "c" (name: cstring) -> rawptr,
    ConfigSubstitute:       proc "c" (config, pat: rawptr, kind: i32) -> b32,
    DefaultSubstitute:      proc "c" (pat: rawptr),
    FontMatch:              proc "c" (config, pat: rawptr, result: ^i32) -> rawptr,
    PatternGetString:       proc "c" (pat: rawptr, object: cstring, n: i32, s: ^cstring) -> i32,
    PatternGetDouble:       proc "c" (pat: rawptr, object: cstring, n: i32, d: ^f64) -> i32,
    PatternDestroy:         proc "c" (pat: rawptr),
    FontList:               proc "c" (config, pat, os: rawptr) -> ^FontSet,
    FontSetDestroy:         proc "c" (fs: ^FontSet),
    ObjectSetCreate:        proc "c" () -> rawptr,
    ObjectSetAdd:           proc "c" (os: rawptr, object: cstring) -> b32,
    ObjectSetDestroy:       proc "c" (os: rawptr),
    __handle:               dynlib.Library,
}

@(private = "file")
FontSet :: struct {
    nfont: i32,
    sfont: i32,
    fonts: [^]rawptr,
}

@(private = "file")
fc: Fc
@(private = "file")
fc_config: rawptr
// Under a Once: a plain `tried` flag races with the kernel's worker thread (§9).
@(private = "file")
fc_once: sync.Once

@(private = "file")
MATCH_PATTERN :: 0 // FcMatchPattern
@(private = "file")
RESULT_MATCH :: 0 // FcResultMatch

@(private = "file")
fc_open :: proc() -> bool {
    sync.once_do(&fc_once, proc() {
        if _, ok := dynlib.initialize_symbols(&fc, "libfontconfig.so.1", "Fc"); ok {
            fc_config = fc.InitLoadConfigAndFonts()
        }
    })
    return fc_config != nil
}

// Resolves a fontconfig pattern to a concrete face. `pattern` is fontconfig's own syntax, so
// "monospace" is the system's fixed-pitch alias and ":charset=e0b0" asks who has that glyph.
@(private)
fc_match :: proc(pattern: string, allocator := context.allocator) -> (f: Found, ok: bool) {
    if !fc_open() {
        return {}, false
    }
    cpat := strings.clone_to_cstring(pattern, context.temp_allocator)
    pat := fc.NameParse(cpat)
    if pat == nil {
        return {}, false
    }
    defer fc.PatternDestroy(pat)

    // User rules, then defaults; skipping either gets a match that ignores the user's config.
    fc.ConfigSubstitute(fc_config, pat, MATCH_PATTERN)
    fc.DefaultSubstitute(pat)

    result: i32
    m := fc.FontMatch(fc_config, pat, &result)
    if m == nil || result != RESULT_MATCH {
        return {}, false
    }
    defer fc.PatternDestroy(m)

    f = pattern_found(m, allocator) or_return
    size: f64
    fc.PatternGetDouble(m, "size", 0, &size) // absent on plenty of matches; 0 is fine
    f.size = f32(size)
    return f, true
}

@(private = "file")
pattern_found :: proc(pat: rawptr, allocator := context.allocator) -> (f: Found, ok: bool) {
    family, file: cstring
    if fc.PatternGetString(pat, "family", 0, &family) != RESULT_MATCH ||
       fc.PatternGetString(pat, "file", 0, &file) != RESULT_MATCH {
        return {}, false
    }
    f.family = strings.clone(string(family), allocator)
    f.path = strings.clone(string(file), allocator)
    return f, true
}

// An EXACT family lookup, not a match: a user rule with binding="strong" can rewrite an
// explicitly named family under fc_match. FcFontList returns faces whose family IS this,
// and nothing when the font is not installed.
@(private)
fc_list_exact :: proc(family: string, allocator := context.allocator) -> (f: Found, ok: bool) {
    if !fc_open() {
        return {}, false
    }
    cfam := strings.clone_to_cstring(family, context.temp_allocator)
    pat := fc.NameParse(cfam)
    if pat == nil {
        return {}, false
    }
    defer fc.PatternDestroy(pat)

    objs := fc.ObjectSetCreate()
    if objs == nil {
        return {}, false
    }
    defer fc.ObjectSetDestroy(objs)
    fc.ObjectSetAdd(objs, "family")
    fc.ObjectSetAdd(objs, "file")
    fc.ObjectSetAdd(objs, "style")

    set := fc.FontList(fc_config, pat, objs)
    if set == nil || set.nfont == 0 {
        return {}, false
    }
    defer fc.FontSetDestroy(set)

    // A family ships many styles. Regular is what a cell grid wants; the first otherwise.
    best := set.fonts[0]
    for i in 0 ..< int(set.nfont) {
        style: cstring
        if fc.PatternGetString(set.fonts[i], "style", 0, &style) == RESULT_MATCH &&
           string(style) == "Regular" {
            best = set.fonts[i]
            break
        }
    }
    return pattern_found(best, allocator)
}

@(private)
fc_available :: proc() -> bool {return fc_open()}
