## 1.4

- An install writes `binds.conf` and `config.conf` whole, over the ones you have. Keep a copy
  of any rows you changed and put them back after.
- A bind's value is a command line: `enter = :open $o_path`. `exec` is gone, `:stage <line>`
  replaces `stage`, and `none` unbinds a key.
- `$o_path`, `$o_name`, `$o_link` and `$o_act` replace `<path>`-style holes. A builtin takes
  each as one argument, and a shell step reads it as a shell variable.
- Every kernel verb is a builtin you can type: `:edit.undo`, `:ring.goto 3`, `:panel.open`.
- A section header can list groups: `[edit] (text)` puts edit documents in `[text]` too. `send`
  in the list gives a key nothing claims to the program. `[:find]`-style sections are gone.
- The picker and held chords are gone. `ctrl+enter` on a listing row opens its path in the
  panel to the left.
- Shift is no longer added to a row for free. Motions get their `shift+` rows written out;
  `ctrl+shift+c` outside the terminal and `shift+tab` are now unbound.
- `[cmdline] live` lists the builtins that re-run as you type, `find` by default. Closing the
  line puts carets and scroll back. `:find` selects at most 1000 matches, from point.
- The home page lists rows missing from either file. The built-in default runs for each.
- The frame is flat: no gradients or shadows, a 1px ring round each panel, and a dropdown is one
  box with a rule between rows.
- The find plugin is now the grep plugin. Plugin API 14: a plugin asks for a bind as a line,
  `":note"`, not `"exec :note"`.
