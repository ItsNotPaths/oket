#+build !linux
package font

// Not written yet; the caller falls back to the built-in bitmap atlas and says so.
//
//   Windows  HKCU\Console\FaceName, else Consolas / Cascadia Mono.
//   macOS    CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, ...).

system_fixed :: proc(allocator := context.allocator) -> (Found, bool) {
    return {}, false
}

resolve :: proc(family: string, allocator := context.allocator) -> (Found, bool) {
    return {}, false
}

find_covering :: proc(r: rune, allocator := context.allocator) -> (Found, bool) {
    return {}, false
}

font_backend :: proc() -> string {
    return "none"
}
