package tests

import "core:testing"
import app "../oket"

// One directory per kind of file, chosen by where the binary is (INSTALL.md §2). The choosing is
// pure so it can be asked about machines this one is not, and these are that question.

// A `bin` directory and nothing else. Not `~/.local/bin` alone: a packaged oket lands in
// `/usr/bin`, and a rule that only recognised the installer we ship would leave every packaged
// copy reading files it was never given.
@(test)
a_bin_directory_is_the_installed_mode :: proc(t: ^testing.T) {
    cases := [?]struct {
        dir:  string,
        mode: app.Install_Mode,
    } {
        {"/home/x/.local/bin", .Installed},
        {"/usr/bin", .Installed},
        {"/usr/local/bin", .Installed},
        {"/opt/oket/bin", .Installed},
        // The near misses. A prefix test would call the first two of these a bin directory, and
        // `sbin` holds programs nobody typed the name of.
        {"/usr/binaries", .Portable},
        {"/home/x/bindings", .Portable},
        {"/usr/sbin", .Portable},
        // Where oket is built and where a tarball is unpacked, which is the whole of Portable.
        {"/home/x/Projects/oket/build", .Portable},
        {"/home/x/Downloads/oket-1.0", .Portable},
        {"/", .Portable},
        {"", .Portable},
    }
    for c in cases {
        testing.expectf(t, app.home_classify(c.dir) == c.mode,
                        "%q classified as %v, wanted %v", c.dir, app.home_classify(c.dir), c.mode)
    }
}

// What Portable MEANS, and what every other test in this suite is standing on when it hands an
// App one scratch directory.
@(test)
portable_puts_all_three_in_one_directory :: proc(t: ^testing.T) {
    h: app.Home
    app.home_set(&h, "/tmp/oket-somewhere")
    defer app.home_destroy(&h)
    testing.expect_value(t, h.mode, app.Install_Mode.Portable)
    testing.expect_value(t, h.config, "/tmp/oket-somewhere")
    testing.expect_value(t, h.data, "/tmp/oket-somewhere")
    testing.expect_value(t, h.state, "/tmp/oket-somewhere")
}

// A second set replaces the first rather than leaking it, which is what lets a test hand one App
// two homes in a row.
@(test)
a_second_home_replaces_the_first :: proc(t: ^testing.T) {
    h: app.Home
    app.home_set(&h, "/tmp/one")
    app.home_set(&h, "/tmp/two")
    defer app.home_destroy(&h)
    testing.expect_value(t, h.config, "/tmp/two")
}

// The test binary is not in a bin directory, so the suite itself resolves Portable. Said out
// loud because every test that writes a file into its App's home depends on it.
@(test)
the_suite_resolves_portable :: proc(t: ^testing.T) {
    h := app.home_resolve()
    defer app.home_destroy(&h)
    testing.expect_value(t, h.mode, app.Install_Mode.Portable)
    testing.expect(t, h.data != "", "no directory beside the test binary")
    testing.expect_value(t, h.config, h.data)
    testing.expect_value(t, h.state, h.data)
}
