# Design decisions

Settled design for `nvim-bodgery`. Protocol facts come from reading the Claude Code 2.1.281 binary, and they can change between releases.

## Principles

The plugin is a bridge between Claude Code and Neovim, and it stays out of the user's way. A Claude terminal behaves like any other buffer: it goes into windows the way `:edit` and `:split` put buffers there, and the plugin respects the user's options wherever one applies. The plugin never changes windows or tabs except the current window, and only on an explicit call. Diff review is the exception: it shows a proposed edit in a window beside Claude, chosen by `opts.diff.window()`. It favors the smallest mechanism that works, and it is meant to be built on.

## Scope

The plugin provides functions, events, and MCP tools, plus a Claude terminal that survives `:mksession` and a `<C-g>` prompt editor. Anything that asks the user to choose (a session to resume, a subtask, a file) goes through `vim.ui.select`, so whatever picker replaces it applies. Richer pickers, archive actions, and the resume policy belong to a UI layer outside the plugin (for this config, `lua/claude/`).

## Launch

`open(config, { cwd?, args?, mods?, win? })` starts the config's agent in a terminal buffer and returns its `bufnr`. Every config is named: there is no default config. Without `mods` or `win` the terminal takes the current window, as Neovim's `:terminal` does. With `mods` it opens in a split that follows `:split` and those modifiers (the `mods` table of `nvim_cmd`), honoring `'splitright'` and `'splitbelow'`. `:Claude [args]` opens a split and passes its modifiers along, so `:vertical Claude`, `:tab Claude`, and `:botright Claude` work as they do for `:split`. `opts.cmd` holds the user's default command and flags.

The launch adds:

- `--mcp-config` pointing at the plugin's MCP endpoint, then `--settings` registering the hooks, both as files under `stdpath('run')`. `--mcp-config` takes several values, so `--settings` follows it to end the list before the terminal's own arguments. MCP config headers expand `${BODGERY_TOKEN}`, checked against 2.1.281, so one config file serves every terminal.
- `CLAUDE_CODE_SSE_PORT`, the auth token, and `EDITOR` in the terminal's environment
- `FORCE_CODE_TERMINAL=true`, which Claude checks when deciding whether the terminal supports IDE integration
- `127.0.0.1` and `localhost` appended to `no_proxy` and `NO_PROXY`, since Claude sends requests through `http_proxy` when one is set

Sessions started this way are the only ones with hooks and custom tools. The plugin also writes `~/.claude/ide/<port>.lock` (`workspaceFolders`, `pid`, `ideName`, `transport`, `authToken`), which the `--ide` connection requires.

## Transport

One localhost HTTP server per Neovim, on `vim.uv`, carries three things: HTTP hooks (`{"type": "http", "url": ..., "headers": {...}}`), the MCP server for custom tools, and the `--ide` websocket. Each terminal gets its own random token in `BODGERY_TOKEN`. Hooks send it as `Authorization: Bearer $BODGERY_TOKEN` (hook header values expand only the environment variables named in the hook's `allowedEnvVars`), and the MCP config sends it the same way, so every hook and tool call maps to its terminal. The websocket authenticates with the lockfile's `authToken` in `X-Claude-Code-Ide-Authorization`. Claude reads that token from the lockfile for the port, so it is shared by every terminal in one Neovim.

Claude posts each hook with a `Content-Length` body and sends every hook from one session over a single kept-alive connection (axios, `Connection: keep-alive`), observed with 2.1.281 and a raw-logging server.

Custom tools need their own MCP server because Claude hides every `mcp__ide__*` tool from the model except `executeCode` and `getDiagnostics`.

## Hooks

The plugin registers:

- `SessionStart` to bind a `session_id` to its terminal. It fires again after `/resume` and `/clear`, which is how the plugin tracks a terminal changing sessions. Claude skips HTTP hooks for `SessionStart`, so this one is a command hook that pipes its input to the same endpoint with `curl`.
- `PreToolUse` and `PostToolUse` on Read, Edit, Write, and NotebookEdit for touched files, and on Bash for background tasks. A background command's `PostToolUse` carries `tool_response.backgroundTaskId`, and `Stop` and `SubagentStop` list the tasks still running in `background_tasks`, so a task missing from that list has finished.
- `SubagentStart` and `SubagentStop`
- `UserPromptSubmit`, `Stop`, and `Notification` for status
- `SessionEnd`

User config can return hook decisions (deny a tool, add context) from `opts.hooks.<Event> = function(input) ... end`.

## Events

`User` autocmds, with `session_id` and `bufnr` in every `ev.data`:

- `ClaudeSessionEnter`, `ClaudeSessionLeave`. On `/resume` or `/clear`, `Leave` for the old session fires before `Enter` for the new one.
- `ClaudeToolUsePre`, `ClaudeToolUsePost`
- `ClaudeFilesChanged`
- `ClaudeStatusChanged` (busy, idle, waiting)
- `ClaudeSubtaskOpen`, `ClaudeSubtaskClose`

## IDE protocol

Claude calls these on the editor:

- `getDiagnostics`, with a `uri` before each file edit and without arguments after it. The reply merges `vim.diagnostic` from all sources with treesitter `ERROR` and `MISSING` nodes (source `treesitter`), and covers loaded buffers only. A `uri` for an unloaded file returns an empty list, since Claude sends one before every edit. Claude feeds diagnostics introduced by its edit back to the model.
- `openDiff`, `close_tab`, `closeAllDiffTabs`. `openDiff` blocks until the user accepts or rejects. Claude reads three replies: `FILE_SAVED` plus contents (accepted, and Claude writes those contents instead of its own), `DIFF_REJECTED`, and `TAB_CLOSED`, which leaves the decision to the terminal prompt. When the user answers in the terminal, Claude calls `close_tab`, and the pending `openDiff` gets `TAB_CLOSED`.

  The review is one buffer holding the proposed contents, in one window. Added lines are highlighted and removed lines show as virtual lines where they were. With `opts.diff.inline` (on by default), a changed line that `linematch` pairs with its old version is highlighted as changed, with inserted characters marked and removed ones shown inline. The user can edit the buffer. `:w` accepts, and deleting or hiding the buffer rejects, so a second diff shown over the first rejects the first. Afterwards the window gets its previous buffer back, or closes if it was opened for the diff.

  `opts.diff.window()` returns the window. The default looks at the current tab:

  - Claude alone: a new vertical split beside it, the one window the plugin opens on its own
  - one other window: that window
  - several: the one nearest Claude in `winlayout()`
  - no Claude window: the current window
- `executeCode`, served as "run Lua in the user's Neovim" with `{ code }`. It is off by default (`opts.execute_code = true` enables it) and should never go on a permission allowlist, since one approval covers `vim.fn.system`.

The plugin sends Claude:

- `selection_changed` on `WinLeave` from file windows and on `ModeChanged` out of visual mode (range from `'<` and `'>`), never from Claude terminals. Claude attaches the most recent one to the next prompt, as selected lines or as "user opened file X". Claude reads only the line numbers, and an end at character 0 excludes that line, so a linewise selection ends at character 0 of the line after it. Leaving a window right after a visual selection, with the cursor and buffer unchanged, sends nothing, so the selection survives the move to the terminal. Automatic sending can be disabled.
- `at_mentioned` from `send_at_mention(range)`. `send_selection()` sends a selection on demand.

## Custom MCP tools

Tools come from `opts.tools = { name = { description, input_schema, handler = function(args, ctx) ... end } }` or `tool(name, spec)`. Handlers run in the main Neovim, and `ctx` carries `session_id` and the terminal `bufnr`. Claude sees them as `mcp__nvim__<name>`. The tool list is read on every `tools/list`, so tools registered mid-session appear without a restart.

Built in: `nvim_help(tag)` returns the section from a tag to the next tag, `nvim_help_search(pattern)` matches tag names through `taglist()`, and `nvim_helpgrep(pattern)` searches full text. `nvim_screen({ highlights? })` returns the screen as text, optionally with runs of `{ row, first, last, group }` in 1-based screen cells.

`nvim_screen` reads the screen by attaching a UI to Neovim's own server (`v:servername`) over a `vim.uv` pipe, with `ext_linegrid` and `ext_hlstate`, and detaching after the first flush that draws the grid. `ext_hlstate` names the group behind each cell (`ui_name` for built-in UI groups such as `EndOfBuffer`, otherwise `hi_name`), which `screenattr()` can't, since it returns only numeric ids. The UI gets `'columns'` by `'lines'`, so attaching doesn't resize the screen, but it forces a full redraw on every UI. The reply is deferred, because Neovim draws only after the handler returns to the event loop.

## Data

`sessions(filter?)` yields one record per session: `id`, `cwd`, `title`, `archived`, `last_activity`, `live` (pid and status), and `bufnr` when a plugin terminal holds it. It filters on `cwd` and `archived` and reads only as much of each file as the requested fields need. Sources:

- transcripts, `~/.claude/projects/<slug>/<id>.jsonl`, for every session
- ccd's index, `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json`, matched on `cliSessionId`, for `title` and `isArchived`
- `~/.claude/sessions/<pid>.json` for live sessions (`status`, `name`, `messagingSocketPath`)

Without a ccd title, `title` falls back, in order, to the last `custom-title` record (from `/rename`), the last `agent-name` record, the live session's `name`, the last `ai-title` record, and the first line of the first prompt. Claude re-appends title records as a session goes on, so they are read from the last 64 KB of the transcript, and `cwd` and the first prompt from the start (up to 1 MB). A `fields` list in the filter skips the reads a caller doesn't need.

`subtasks(session)` lists subagents (`<session>/subagents/agent-<id>.jsonl` with `.meta.json`) and background tasks (tool calls in the main transcript).

`touched(session)` lists files Claude read or edited. It comes from transcript tool calls and `file-history-*` records, so it works for sessions the plugin did not launch, and hooks keep it current for live ones.

## Switching sessions

`resume(id, bufnr?, config?)` has the adapter resume session `id` in the target terminal. Claude's adapter types `/resume <id>`. When the `active` chain reaches `new`, it opens a new terminal in the current window with the adapter's resume arguments, leaving any other tab that shows an old terminal untouched. Typing into a terminal goes through `terminal.submit`, where `on_busy = 'error' | 'interrupt' | 'queue' | 'prompt'` decides what happens mid-turn.

`toggle(bufnr?, config?)` hides the target terminal when it shows in the current tab (closing its window, or showing the alternate buffer when it is the tab's only window) and otherwise shows it in the window `show.window` returns. `show` and `hide` do one half each, and `select.terminals()` picks a terminal and shows it.

Without `bufnr`, the target is the current window's terminal, else the first match of the config's `active` list, which defaults to `{ 'window', 'tab', 'global', 'new' }`. The records behind `window`, `buffer`, `tab`, and `global` are `w:`, `b:`, `t:`, and `g:bodgery_term`. Toggling goes to the most recently chosen terminal that makes sense where the user is. Moving between windows never changes a record, since glancing at a terminal is not choosing it. Records change only on these events:

- Opening a terminal: it fills the current scope (the last of `window`, `buffer`, `tab` in `active`, so `t:` by default) and `g:`. `g:` holds the latest choice, so a tab with no record of its own gets the terminal used last.
- The chain finding a terminal through `global`, `project`, `pick`, or a function after an empty scoped record: the last empty scoped record takes it, so a tab that falls through to `g:` keeps that terminal from then on. A hit on a scoped record writes nothing.
- An explicit choice (`toggle(b)`, `show(b)`, the picker): the current scope and `g:` take it.
- A window showing terminal `a` switching to terminal `b` (`BufLeave` and `BufEnter` in the same window): every record in the tab that held `a` (`t:`, and `w:`/`b:` of its windows) takes `b`, or the current scope does when none did. A record pointing at another terminal is left alone, so a swap in a pinned window does not retarget the rest of the tab. `g:` takes `b`, and other tabs are untouched.
- A terminal exiting: every record holding it clears, and `g:` passes to the most recently chosen terminal left.

## Session restore

Neovim restores a terminal by re-running its command, which would start a new conversation. On `SessionWritePost` the plugin saves a map from each Claude terminal's buffer name (`term://<cwd>//<pid>:<cmd>`) to its `session_id` and `cwd` in `stdpath('state')/bodgery/terminals.json`, merged with entries from other Neovims. `opts.restore.max_age` purges entries not written for that long.

A session file restores a terminal with `badd <name>`, then `edit <name>`, which fires `BufReadCmd`, then `silent file <name>`, which renames the new terminal back to the saved name. Neovim's own `BufReadCmd` for `term://*` is defined first, so it runs first, but it skips buffers that have `b:term_title`. The plugin sets that variable on `BufNew` for names in the state file (`badd` fires `BufNew` before any read), and its own `BufReadCmd` then launches Claude in the buffer with `--resume <id>`. The rename keeps the key stable across restores. When a live Claude process or another plugin terminal already holds the session, the terminal starts a new conversation and says so with a notification. The session file must be sourced after the plugin loads and the terminal's config exists (from `setup()` or detection), or Neovim relaunches the stale command.

The key cannot use `v:this_session`: session managers that `mksession` to a temp file (this config's `lua/session.lua`) make it point at the temp path during `SessionWritePost`.

## Prompt editor

`<C-g>` opens `$EDITOR` on a temp file holding the draft prompt, waits for the editor to exit, and reads the file back. The plugin sets `EDITOR` to a wrapper that opens the file in this Neovim and blocks until its buffer is hidden. `opts.editor.open(file)` picks the window. With "Show responses in IDE" (`externalEditorContext`) on, the file also carries Claude's last response.

## Open questions

- Whether to adapt claudecode.nvim's `server/` websocket code for the HTTP server.
- How to map a websocket connection to its terminal. The shared lockfile token can't identify it, so `selection_changed` and `at_mentioned` either go to every connected session or need another signal.

## Sources

The Claude Code binary is at `/opt/homebrew/Caskroom/claude-code@latest/<version>/claude`. Its JavaScript is minified, so verification means searching `strings -n 6` output for literal names and reading the surrounding code:

- `callIdeRpc(` and `g0n(` (minified name, changes per build) for the calls Claude makes to the editor: `openDiff`, `close_tab`, `closeAllDiffTabs`, `getDiagnostics`
- `"FILE_SAVED"`, `"DIFF_REJECTED"`, and `"TAB_CLOSED"` for how Claude reads an `openDiff` reply
- `"mcp__ide__executeCode","mcp__ide__getDiagnostics"` for the allowlist of IDE tools shown to the model
- `("selection_changed")` and `at_mentioned` for the notification formats
- `opened_file_in_ide` and `selected_lines_in_ide` for how the selection is attached to a prompt
- `beforeFileEdited` for the pre-edit `getDiagnostics` call
- `X-Claude-Code-Ide-Authorization` and `workspaceFolders` (lockfile parsing) for the websocket connection
- `allowedEnvVars` for the HTTP hook schema
- `HTTP hooks are not supported for` for the events that skip HTTP hooks (`SessionStart`, `Setup`)
- `FORCE_CODE_TERMINAL` and `CLAUDE_CODE_SSE_PORT`
- `externalEditorContext` for the prompt editor's response context

Hook payloads in `test/fixtures/hooks/` were recorded from 2.1.281 by `test/capture-hooks.lua`. Rerun it after a Claude upgrade.

Local data read directly:

- `~/.claude/sessions/<pid>.json` for live sessions
- `~/.claude/projects/<slug>/<id>.jsonl` and `<id>/subagents/` for transcripts and subagents
- `~/Library/Application Support/Claude/claude-code-sessions/` for ccd's index

`:mksession` terminal behavior: in `nvim --clean`, open `:terminal sleep 30`, run `:mksession`, and source the file in a new instance. The session file keeps the old `term://.../<pid>:...` name, and the restored terminal gets a new PID.

claudecode.nvim was read at commit `2390c6e` (<https://github.com/coder/claudecode.nvim>):

- `lua/claudecode/server/` for the websocket server
- `diff.lua` for the diff protocol and layout code
- `tools/get_diagnostics.lua` for the error on unloaded files
- `terminal.lua` for the environment, including the `no_proxy` fix from issue #70
- `lockfile.lua` and `selection.lua`

Its `PROTOCOL.md` lists tools that 2.1.281 never calls, so trust the binary over it.

