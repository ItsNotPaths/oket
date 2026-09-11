package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../desc"
import "../input"
import "../store"
import "../txt"
import app "../oket"

// What a start does (§13): the plugins an earlier one died in, the work a crash left, and the
// ring the last clean exit had. Three files' worth of behaviour that only exists BETWEEN runs,
// so every test here is two Apps over one home.

// --- the quarantine ---

// Stage 9 left this half: a plugin the net could not unwind takes the process with it, and the
// only place that can notice is the next start.
@(test)
a_quarantined_plugin_is_not_autoloaded :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-start-quarantine")
    if !ok {
        return
    }
    defer close_plug_app(&a)
    app.plug_init(&a)

    // What the fault handler leaves: one name, one `write`, no formatting (fault.odin).
    quarantine, _ := filepath.join({a.home.state, app.QUARANTINE_FILE}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(quarantine, transmute([]u8)string("example\n")),
                         nil)

    app.quarantine_open(&a)
    testing.expect(t, app.quarantined(&a, "example"), "the sweep did not read the report")
    app.plug_autoload(&a)
    testing.expect_value(t, app.plug_find(&a, "example"), -1)
    testing.expect(t, strings.contains(a.message, "example"), a.message)

    // An explicit load is the author saying they fixed it, so the name leaves the list and the
    // file: a quarantine you cannot lift is a plugins directory you have to edit by hand.
    testing.expect(t, app.plug_load(&a, app.plug_path(&a, "example")), a.message)
    testing.expect(t, !app.quarantined(&a, "example"), "the quarantine outlived the load")
    testing.expect(t, !os.exists(quarantine), "the last name left, and the file stayed")
}

// The report is a file two starts share, and the second one reads what the first appended.
@(test)
the_report_is_read_by_the_next_start :: proc(t: ^testing.T) {
    home, made := scratch(t, "oket-start-report")
    if !made {
        return
    }
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    app.home_set(&a.home, home)
    app.quarantine_open(&a)
    if !testing.expect(t, a.report != nil, "no fd for the handler to write to") {
        close_plug_app(&a)
        return
    }
    // What the handler does, minus the signal: one append of a name and a newline.
    _, err := os.write(a.report, transmute([]u8)string("files\n"))
    testing.expect_value(t, err, nil)
    close_plug_app(&a)

    b, remade := bare_app()
    if !testing.expect(t, remade, "no second App") {
        return
    }
    defer close_plug_app(&b)
    app.home_set(&b.home, home)
    app.quarantine_open(&b)
    testing.expect(t, app.quarantined(&b, "files"), "the next start read no report")
}

// --- the home page ---

// The page is a DOCUMENT, and `enter` over a row is one bind over one field. The row's span is
// the path it shows, so what hover underlines is what `enter` acts on (§14).
@(test)
the_home_page_offers_recovered_work :: proc(t: ^testing.T) {
    home, made := scratch(t, "oket-start-home")
    if !made {
        return
    }
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_plug_app(&a)
    app.home_set(&a.home, home)

    file, _ := filepath.join({home, "alpha.txt"}, context.temp_allocator)
    id := scratch_doc(&a, file, "xyz")
    app.docs_settle(&a) // the journal opens, with the file's own bytes as its base
    gen, _ := store.store_gen(&a.docs, id)
    store.store_submit(&a.docs, id, gen, {txt.Edit{0, 0, "Q", 0, 0}}) // a write, as a plugin's is
    app.docs_settle(&a)
    testing.expect(t, app.journal_detach(&a, id), "the document was not being journaled")
    app.doc_close(&a, id)

    testing.expect(t, app.home_news(&a), "a journal was left and the start had nothing to say")
    page := app.home_open(&a)
    app.ring_add(&a, page)
    testing.expect_value(t, app.doc_kind(&a, page), app.KIND_HOME)

    d := store.store_descriptor(&a.docs, page)
    defer desc.release(d)
    line := -1
    for f in d.fields {
        if f.name == "path" {
            line = f.line
        }
    }
    if !testing.expect(t, line >= 0, "the page listed no recovered work") {
        return
    }
    lo, hi, spanned := desc.field_span(d, line, "path")
    testing.expect(t, spanned, "the row named no path")
    row := doc_line_text(&a, page, line)
    testing.expect_value(t, row[lo:hi], file)

    // The bind the page rests on: narrower than the surface row it shadows, because `:open`
    // there would open the file and leave the journal beside it. One row for every section,
    // because the ROW says which verb it wants (home.odin).
    b, bound := input.bind_find(a.binds[:], chord("RTRN"), .Surface, app.KIND_HOME)
    if !testing.expect(t, bound, "enter is not bound over a home page") {
        return
    }
    liner, is_line := b.target.(input.Bind_Line)
    testing.expect(t, is_line, "enter over a home page is not a command line")
    testing.expect_value(t, liner.text, ":home enter")

    // Which verb that is, is the ROW's: this one carries a path and asks for `:recover`. What
    // it recovers is journal_test's, because taking work back needs the editor plugin.
    app.active(&a).view.point.head.line = line
    testing.expect(t, app.home_enter(&a), a.message)
    testing.expect(t, !strings.contains(a.message, "not an offer"), a.message)

    // A row that is prose says so rather than running the first verb it can spell.
    app.active(&a).view.point.head.line = 0
    testing.expect(t, !app.home_enter(&a), "the version line was taken as an offer")
    testing.expect(t, strings.contains(a.message, "not an offer"), a.message)
}

// The page is the DEFAULT DOCUMENT, not a report that only opens after a crash: a quiet start
// still gets the version, the working directory as a row, and no listing it did not ask for.
@(test)
a_quiet_start_still_opens_the_page :: proc(t: ^testing.T) {
    home, made := scratch(t, "oket-start-default")
    if !made {
        return
    }
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_plug_app(&a)
    app.home_set(&a.home, home)

    testing.expect(t, !app.home_news(&a), "an untouched home had news")
    page := app.home_open(&a)
    app.ring_add(&a, page)
    testing.expect(t, strings.contains(doc_line_text(&a, page, 0), "oket"), "no version line")

    cwd, _ := os.get_working_directory(context.temp_allocator)
    d := store.store_descriptor(&a.docs, page)
    defer desc.release(d)
    at := -1
    for f in d.fields {
        if f.name == "file" {
            at = f.line
        }
    }
    if !testing.expect(t, at >= 0, "the page offered no file to open") {
        return
    }
    lo, hi, spanned := desc.field_span(d, at, "file")
    testing.expect(t, spanned, "the row named no file")
    testing.expect_value(t, doc_line_text(&a, page, at)[lo:hi], cwd)
}

// How this start came up, which a start cannot answer from the outside: every plugin held back
// looks exactly like every plugin broken (§13).
@(test)
the_page_says_it_is_a_safe_start :: proc(t: ^testing.T) {
    home, made := scratch(t, "oket-start-safe")
    if !made {
        return
    }
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_plug_app(&a)
    app.home_set(&a.home, home)

    page := app.home_open(&a)
    testing.expect(t, !strings.contains(doc_line_text(&a, page, 1), "safe mode"),
                   "an ordinary start called itself safe")

    a.start = .Safe
    app.home_refresh(&a)
    testing.expect(t, strings.contains(doc_line_text(&a, page, 1), "safe mode"),
                   doc_line_text(&a, page, 1))
}

// The two ways a chord goes wrong that no other surface reports: a line binds.conf could not be
// read at all, and a row a plugin asked for that the file answers with something else.
@(test)
the_page_lists_what_is_wrong_with_the_binds :: proc(t: ^testing.T) {
    home, made := scratch(t, "oket-start-binds")
    if !made {
        return
    }
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_plug_app(&a)
    app.home_set(&a.home, home)

    // A plugin asks; the file already answers that chord with something else, so the row it
    // asked for is not the row that fires (§8).
    app.binds_request(&a, "hello", "global", "f9", "exec :note")
    unmet := app.binds_unmet(&a, context.temp_allocator)
    testing.expect_value(t, len(unmet), 0) // nothing holds f9 yet, so nothing is refused

    app.binds_parse(&a, "[global]\nctrl+b f = exec :home\nf9 = exec :home\n", app.BINDS_NAME)
    testing.expect_value(t, len(a.gripes), 1)
    unmet = app.binds_unmet(&a, context.temp_allocator)
    if !testing.expect(t, len(unmet) == 1, "a chord the file answers itself went unreported") {
        return
    }
    testing.expect_value(t, unmet[0].owner, "hello")
    testing.expect_value(t, unmet[0].held, ":home")

    testing.expect(t, app.home_news(&a), "a refused row and a bad line were not news")
    page := app.home_open(&a)
    text := doc_text(&a, page)
    testing.expect(t, strings.contains(text, "f9"), text)
    testing.expect(t, strings.contains(text, "a sequence is two chords"), text)

    // A second read replaces what the first found rather than saying it twice: binds.conf is
    // read twice in a sync, and a list that only grew would report one typo as two.
    app.binds_parse(&a, "[global]\nctrl+b f = exec :home\nf9 = exec :home\n", app.BINDS_NAME)
    testing.expect_value(t, len(a.gripes), 1)
}

// What shipped, off notes.md in the data directory. The newest section and no more: the page is a
// start's report, and the file is one row away.
@(test)
the_page_shows_the_newest_notes :: proc(t: ^testing.T) {
    home, made := scratch(t, "oket-start-notes")
    if !made {
        return
    }
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_plug_app(&a)
    app.home_set(&a.home, home)

    notes, _ := filepath.join({home, app.NOTES_NAME}, context.temp_allocator)
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, "# notes\n\n## v2\n\n- the new thing\n")
    for i in 1 ..= app.NOTES_LINES { // one past the cap
        fmt.sbprintfln(&b, "- filler %d", i)
    }
    strings.write_string(&b, "\n## v1\n\n- the old thing\n")
    testing.expect_value(t, os.write_entire_file(notes, b.buf[:]), nil)

    page := app.home_open(&a)
    text := doc_text(&a, page)
    testing.expect(t, strings.contains(text, "v2"), text)
    testing.expect(t, strings.contains(text, "the new thing"), text)
    testing.expect(t, !strings.contains(text, "the old thing"), "the page listed every release")

    // The cap: the newest section runs one line past NOTES_LINES, and that line stays in the file.
    last := fmt.tprintf("filler %d", app.NOTES_LINES - 1)
    over := fmt.tprintf("filler %d", app.NOTES_LINES)
    testing.expect(t, strings.contains(text, last), text)
    testing.expect(t, !strings.contains(text, over), "the page showed past the cap")

    // The file itself is a row, so `enter` over it opens what the page could not fit.
    d := store.store_descriptor(&a.docs, page)
    defer desc.release(d)
    offered := false
    for f in d.fields {
        if f.name != "file" {
            continue
        }
        row := doc_line_text(&a, page, f.line)
        offered ||= row[f.lo:f.hi] == notes
    }
    testing.expect(t, offered, "the page did not offer notes.md")
}

// The page's other verb: the work was not wanted, and the file on disk already says so.
@(test)
recover_drop_throws_the_work_away :: proc(t: ^testing.T) {
    home, made := scratch(t, "oket-start-drop")
    if !made {
        return
    }
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_plug_app(&a)
    app.home_set(&a.home, home)

    file, _ := filepath.join({home, "alpha.txt"}, context.temp_allocator)
    id := scratch_doc(&a, file, "xyz")
    app.docs_settle(&a)
    gen, _ := store.store_gen(&a.docs, id)
    store.store_submit(&a.docs, id, gen, {txt.Edit{0, 0, "Q", 0, 0}})
    app.docs_settle(&a)
    testing.expect(t, app.journal_detach(&a, id), "the document was not being journaled")
    app.doc_close(&a, id)

    journal := strings.clone(app.journal_path(&a, file))
    defer delete(journal)
    testing.expect(t, os.exists(journal), "no journal was left to drop")
    app.cl_exec(&a, fmt.tprintf(":recover drop %s", file))
    testing.expect(t, !os.exists(journal), "the drop kept the journal")
    testing.expect_value(t, len(app.recover_scan(&a)), 0)

    // A second drop has nothing to find, and says so rather than pretending it worked.
    app.cl_exec(&a, fmt.tprintf(":recover drop %s", file))
    testing.expect(t, strings.contains(a.message, "nothing was journaled"), a.message)
}

// The page is not a dialog: a `:plug load` or a recover has to show on the page that offered
// it, without closing it first.
@(test)
a_recover_rewrites_the_page_that_offered_it :: proc(t: ^testing.T) {
    home, made := scratch(t, "oket-start-quiet")
    if !made {
        return
    }
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_plug_app(&a)
    app.home_set(&a.home, home)

    // Must not collide with baked notes.md fallback which contains "hello".
    tag := "qtest_hello_xyz"
    append(&a.quarantined, strings.clone(tag))
    page := app.home_open(&a)
    testing.expect(t, strings.contains(doc_text(&a, page), tag), doc_text(&a, page))

    app.quarantine_clear(&a, tag)
    app.home_refresh(&a)
    testing.expect(t, !strings.contains(doc_text(&a, page), tag),
                   "the page kept a plugin that had been taken back")
}

// --- the session ---

// A session is a list of command lines, so restoring one is running them and there is no
// format to version. Off unless config.conf says otherwise.
@(test)
a_session_restores_the_ring :: proc(t: ^testing.T) {
    // The browser, because a session is a list of `:open` lines and a DIRECTORY is the `files`
    // kind's — there is no listing of the kernel's own to restore into. Its home is the session
    // home, so both Apps below find the same plugin beside the same config.
    a, ok := plug_app(t, "oket-start-session", "plugins/files")
    if !testing.expect(t, ok, "no App") {
        return
    }
    home := strings.clone(home_dir(a.home), context.temp_allocator)
    one, _ := filepath.join({home, "one"}, context.temp_allocator)
    two, _ := filepath.join({home, "two"}, context.temp_allocator)
    for dir in ([?]string{one, two}) {
        if err := os.make_directory(dir); err != nil {
            testing.expectf(t, false, "cannot make %s: %v", dir, err)
            close_plug_app(&a)
            return
        }
    }
    config, _ := filepath.join({home, app.CONFIG_NAME}, context.temp_allocator)
    testing.expect_value(t,
                         os.write_entire_file(config,
                                              transmute([]u8)string("[session]\nrestore = on\n")),
                         nil)

    app.plug_init(&a)
    testing.expect(t, app.plug_load(&a, app.plug_path(&a, "files")), a.message)
    app.config_load(&a)
    testing.expect(t, a.config.restore, "config.conf said on and the App read off")

    app.cl_exec(&a, fmt.tprintf(":open %s", one))
    app.cl_exec(&a, fmt.tprintf(":open %s", two))
    app.session_save(&a)
    close_plug_app(&a)

    b, remade := bare_app()
    if !testing.expect(t, remade, "no second App") {
        return
    }
    defer close_plug_app(&b)
    app.home_set(&b.home, home)
    app.plug_init(&b)
    testing.expect(t, app.plug_load(&b, app.plug_path(&b, "files")), b.message)
    app.config_load(&b)
    testing.expect(t, app.session_restore(&b), "the session restored nothing")
    // Both slots came back, and the one that was focused is the one you come back to.
    testing.expect_value(t, app.doc_title(&b, app.ring_focused(&b).doc), two)
    testing.expect_value(t, app.doc_title(&b, app.ring_get(&b, 1).doc), one)
}

// PANELS.md stage 4's other gate: a two-panel layout round-trips through a clean exit. The
// strip is `@N` on the same `:open` lines, so there is still no session format — a layout is
// two addresses, and both are ones the user could have typed. A slot no panel stands on rides
// along, and its line runs before the strip is built so it cannot drag the focused panel.
@(test)
a_session_restores_the_strip :: proc(t: ^testing.T) {
    a, ok := plug_app(t, "oket-start-strip", "plugins/files")
    if !testing.expect(t, ok, "no App") {
        return
    }
    home := strings.clone(home_dir(a.home), context.temp_allocator)
    one, _ := filepath.join({home, "one"}, context.temp_allocator)
    two, _ := filepath.join({home, "two"}, context.temp_allocator)
    three, _ := filepath.join({home, "three"}, context.temp_allocator)
    for dir in ([?]string{one, two, three}) {
        if err := os.make_directory(dir); err != nil {
            testing.expectf(t, false, "cannot make %s: %v", dir, err)
            close_plug_app(&a)
            return
        }
    }
    config, _ := filepath.join({home, app.CONFIG_NAME}, context.temp_allocator)
    testing.expect_value(t,
                         os.write_entire_file(config,
                                              transmute([]u8)string("[session]\nrestore = on\n")),
                         nil)
    app.plug_init(&a)
    testing.expect(t, app.plug_load(&a, app.plug_path(&a, "files")), a.message)
    app.config_load(&a)

    app.cl_exec(&a, fmt.tprintf(":open %s", one))
    app.panel_open(&a)
    app.cl_exec(&a, fmt.tprintf(":open %s", two))
    app.panel_step(&a, -1) // focus back on the left, so the file has to carry that too
    app.cl_exec(&a, fmt.tprintf(":open %s", three)) // slot 3, standing in no panel
    app.ring_move(&a, app.Spot{app.ring_lane(&a), 1}) // and panel 1 back where it stood
    app.session_save(&a)
    close_plug_app(&a)

    b, remade := bare_app()
    if !testing.expect(t, remade, "no second App") {
        return
    }
    defer close_plug_app(&b)
    app.home_set(&b.home, home)
    app.plug_init(&b)
    testing.expect(t, app.plug_load(&b, app.plug_path(&b, "files")), b.message)
    app.config_load(&b)
    testing.expect(t, app.session_restore(&b), "the session restored nothing")

    testing.expect_value(t, len(b.panels), 2)
    testing.expect_value(t, b.focus, 0)
    for want, i in ([?]string{one, two}) {
        p := app.panel_get(&b, i)
        slot := app.panel_slot(&b, p)
        if !testing.expectf(t, slot != nil, "panel %d came back standing on nothing", i + 1) {
            return
        }
        testing.expect_value(t, app.doc_title(&b, slot.doc), want)
    }
    third := app.ring_get(&b, 3)
    if testing.expect(t, third != nil, "slot 3 came back empty") {
        testing.expect_value(t, app.doc_title(&b, third.doc), three)
    }
}

// A key config.conf does not know is reported, and the rows around it still land. Same rule
// binds.conf follows: one typo does not cost the file, and it does not go quiet either.
@(test)
a_key_no_setting_owns_is_reported :: proc(t: ^testing.T) {
    home, made := scratch(t, "oket-start-badkey")
    if !made {
        return
    }
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_plug_app(&a)
    app.home_set(&a.home, home)

    config, _ := filepath.join({home, app.CONFIG_NAME}, context.temp_allocator)
    text := "[session]\nrestor = on\nrestore = yes\n"
    testing.expect_value(t, os.write_entire_file(config, transmute([]u8)text), nil)

    app.config_load(&a)
    testing.expect(t, strings.contains(a.message, "restor"), a.message)
    testing.expect(t, a.config.restore, "the row after the typo was dropped with it")
}

// A gap the parser cannot read keeps the setting's own default, not zero: silently reading it
// as nothing would put two documents flush against each other (config.odin).
@(test)
a_gap_that_does_not_parse_keeps_the_default :: proc(t: ^testing.T) {
    home, made := scratch(t, "oket-start-gap")
    if !made {
        return
    }
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_plug_app(&a)
    app.home_set(&a.home, home)
    config, _ := filepath.join({home, app.CONFIG_NAME}, context.temp_allocator)

    testing.expect_value(t,
                         os.write_entire_file(config, transmute([]u8)string("[strip]\ngap = 12\n")),
                         nil)
    app.config_load(&a)
    testing.expect_value(t, a.config.gap, 12)

    for bad in ([?]string{"[strip]\ngap = wide\n", "[strip]\ngap = -3\n"}) {
        testing.expect_value(t, os.write_entire_file(config, transmute([]u8)bad), nil)
        app.config_load(&a)
        testing.expect_value(t, a.config.gap, app.GAP_DEFAULT)
    }
}

// Off by default: a start that reopens what you closed the hard way is worse than a start that
// does nothing.
@(test)
a_session_is_not_written_unless_it_is_asked_for :: proc(t: ^testing.T) {
    home, made := scratch(t, "oket-start-nosession")
    if !made {
        return
    }
    a, ok := bare_app()
    if !testing.expect(t, ok, "no App") {
        return
    }
    defer close_plug_app(&a)
    app.home_set(&a.home, home)
    app.config_load(&a)
    testing.expect(t, !a.config.restore, "the session was on with no config.conf at all")

    app.ring_add(&a, listing_doc(&a, home))
    app.session_save(&a)
    session, _ := filepath.join({home, app.SESSION_NAME}, context.temp_allocator)
    testing.expect(t, !os.exists(session), "a session file was written unasked")
    testing.expect(t, !app.session_restore(&a), "a session restored with the setting off")
}

// One line of a document, by number.
@(private = "file")
doc_line_text :: proc(a: ^app.App, id: store.Id, line: int) -> string {
    return string(txt.doc_line(store.store_doc(&a.docs, id), line))
}
