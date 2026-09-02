package tests

import "core:testing"
import "../conf"

// The one flat format (§4). One parser for both files the kernel writes, so a grammar change
// cannot land in binds.conf and miss config.conf.

@(test)
conf_reads_sections_and_values :: proc(t: ^testing.T) {
    rows, errs := conf.parse(
        `# a comment
        loose = before any header

        [browser]
        enter = stage :open <path>
        # another
        d     = exec rm <path>

        [ text ]
        ctrl+s = edit.save`,
    )
    testing.expect_value(t, len(errs), 0)
    testing.expect_value(t, len(rows), 4)

    testing.expect_value(t, rows[0], conf.Row{"", "loose", "before any header", 2})
    testing.expect_value(t, rows[1], conf.Row{"browser", "enter", "stage :open <path>", 5})
    testing.expect_value(t, rows[2], conf.Row{"browser", "d", "exec rm <path>", 7})
    // A header is trimmed, so `[ text ]` and `[text]` are one section.
    testing.expect_value(t, rows[3], conf.Row{"text", "ctrl+s", "edit.save", 10})
}

// The value is the rest of the line, unquoted: a command line holds `=`, `#` and spaces, and
// none of them are syntax.
@(test)
conf_takes_the_value_whole :: proc(t: ^testing.T) {
    rows, errs := conf.parse("[global]\nctrl+f = exec sed -i 's/a=b/c#d/' <path>")
    testing.expect_value(t, len(errs), 0)
    testing.expect_value(t, len(rows), 1)
    testing.expect_value(t, rows[0].value, "exec sed -i 's/a=b/c#d/' <path>")
}

// A bad row is reported and skipped: one typo does not cost the file.
@(test)
conf_skips_a_bad_row_and_names_it :: proc(t: ^testing.T) {
    rows, errs := conf.parse("[global\nno separator\nkey =\n= value\nctrl+s = edit.save")
    testing.expect_value(t, len(rows), 1)
    testing.expect_value(t, rows[0].key, "ctrl+s")
    testing.expect_value(t, rows[0].section, "") // the broken header never opened one

    testing.expect_value(t, len(errs), 4)
    testing.expect_value(t, errs[0], conf.Error{1, "a section header wants a closing ]"})
    for e, i in errs[1:] {
        testing.expect_value(t, e.line, i + 2)
        testing.expect_value(t, e.why, "expected `key = value`")
    }
}
