# oket release notes

Newest first. A section is one release, headed `## <version>`. The home page shows the top
section at every start, so keep it short and keep the first lines the ones that change what you
type.

## 0.3

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