# oket release notes\

Newest first. A section is one release, headed `## <version>`. The home page shows the top
section at every start, so keep it short and keep the first lines the ones that change what you
type.

## 1.3

- `:grep <args>` runs `grep -rn` in the workspace and opens the result in the `grep` lane.
  `up` and `down` step one match at a time, and `enter` or a double-click opens it.
- While the command line holds `:find <text>`, every match in the document is marked as you
  type. `up` and `down` pick the one `enter` lands on. `:find` also takes its pattern from a pipe.
- `ctrl+up` and `ctrl+down` jump to the blank line before or after a paragraph.
- binds.conf takes `[cmdline]` for the command line, and `[:find]`-style sections for the line
  while its last builtin step is that verb.
- An update keeps a plugin you edited and says so on the home page. Each plugin's source ships
  beside its `.so`.
- The indent plugin draws a tab's indent as a line, a space's as a dot, and a line down each
  scope. `[indent] marks` and `[indent] guides` turn them on.
- `:binds` and `:config` open their files. A save is read at once, with no restart.
- The menubar shows each row's bind.
- `:openlink` follows the link under point: a URI goes to the browser, `path:line` opens in the
  ring. `alt+enter` runs it, and so does a double-click in the terminal. `[openlink] browser`
  names the browser command.
- The terminal finds links, both OSC 8 and plain ones in the text. `ctrl+v` pastes there.

## 0.4

- `:harness <file> <plugin>...` runs a file of steps in a second oket with the crash net off, so
  a plugin bug drops a core instead of being recovered. A step is a command line, a chord
  (`> ctrl+shift+k`), text to type, or a check (`! text ~ hello`) that waits until it holds; one
  that fails names its line in N0, where `enter` opens it. A plugin is a source directory to
  build or the name of one installed, and nothing else loads. `--dump` adds the document, its
  descriptor and every publisher's colour runs after each step.
- `:get` also answers `message`, `lines`, `text`, `desc` and `spans`. `spans` says who published
  each colour run, which nothing else shows.
- `:oket update` fetches the latest release and installs it, in N0. Then it restarts.
- `ctrl+f` filters a list: the file browser, the theme list, the grammar list. `esc` clears
  the filter. Typing without it still edits the name.
- `[theme] name` in `config.conf` picks a theme, and the switch shows on the next frame.
  gruvbox ships. A helix theme file dropped into the themes folder works as it is.
- `:ring themer` lists the themes you have and the ones in the helix repo. `enter` stages the
  chain that installs and switches, `del` the one that removes. You read the line before you
  run it.
- Chains take `||`: the step after it runs when the step before failed, the way `&&` runs on
  success.
- `:get panels` puts kernel state on the pipe (also panel, slot, slots, kind, file).
  `:set <section>.<key> <value>` changes a setting for the session. `:do` runs the lines piped
  into it, so `:get panels | awk '...' | :do` is a loop.
- `@*` targets every panel, and `:close #*` closes every slot.
- `[alias] name = line` in `config.conf` names a chain as a new verb. `panel.equalize` ships
  as one: it gives every panel an equal share of the strip.
- The hello and popup plugins folded into one example plugin.
- The helper library is split by section, and `stage.sh` finds every helper file itself.