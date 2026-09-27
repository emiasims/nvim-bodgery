# TODO

## API (`lua/bodging/init.lua`)

- `tool`: move out of init, which holds only the user-facing API (functions keymaps and autocmds call). It only forwards to `M.tools.register`.
- Pick one argument order for every function. `open(config, opts?)` and `sessions(config, filter?)` put the config first, `touched(id, config)`, `resume(id, bufnr?, config?)`, `toggle(bufnr?, config?)` put it last, and the pickers mix both.
- Cookbook recipes: one global CLI, one CLI per tab, a harness tab (chat list left, chat center, toggleable files/changes/general panels right).

## Other

- Rename `harness` to `cli`, as sidekick.nvim does.
- Compare sidekick.nvim features, starting with its autoread setup.
- Type annotations everywhere, fix diagnostics.
- Script that generates vimdoc from the API.
- Config options for auto-sending the file and the selection, where missing.
- File sending is inconsistent, and sometimes sends the prompt file just used to edit a prompt.
- Rename bodging.nvim to nvim-bodgery.
- Skills: a general nvim-config skill and a bodgery config skill.
- A skills directory, or a config option, for adding custom skills.
- Prompt filetype as a markdown subtype (`markdown.prompt` or `prompt.markdown`) in place of `bodge-prompt`.
- In a prompt file opened from the CLI (`<C-g>`), use the CLI's cwd.
- `ZQ` in a prompt file quit all of nvim. It should close that window and cancel the edit, mirroring `ZZ`.
