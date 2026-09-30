# TODO

## API (`lua/bodgery/init.lua`)

- `tool`: move out of init, which holds only the user-facing API (functions keymaps and autocmds call). It only forwards to `M.tools.register`.
- Pick one argument order for every function. `open(config, opts?)` and `sessions(config, filter?)` put the config first, `touched(id, config)`, `resume(id, bufnr?, config?)`, `toggle(bufnr?, config?)` put it last, and the pickers mix both.
- Rework target records (rules in DECISIONS.md, Switching sessions). They work but take four separate events to explain. Known rough edges: `hide()` on a terminal alone in its tab shows the window's previous buffer, which counts as a swap when that buffer is another terminal. A swap reaches `b:` only for buffers shown in the tab. `pick` in `active` and explicit choices write different scopes.
- Cookbook recipes: one global CLI, one CLI per tab, a harness tab (chat list left, chat center, toggleable files/changes/general panels right).

## Other

- `ccd_dir` defaults to the macOS path (`~/Library/Application Support/Claude/claude-code-sessions`). Find where Claude Desktop keeps its session records on Windows and Linux and default to those.
- Rename `harness` to `cli`, as sidekick.nvim does.
- Compare sidekick.nvim features, starting with its autoread setup.
- Type annotations everywhere, fix diagnostics.
- Script that generates vimdoc from the API.
- Config options for auto-sending the file and the selection, where missing.
- File sending is inconsistent, and sometimes sends the prompt file just used to edit a prompt.
- Skills: a general nvim-config skill and a bodgery config skill.
- A skills directory, or a config option, for adding custom skills.
- In a prompt file opened from the CLI (`<C-g>`), use the CLI's cwd.
- `ZQ` in a prompt file quit all of nvim. It should close that window and cancel the edit, mirroring `ZZ`.
