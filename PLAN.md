# Plan

Build order for the first version. [DECISIONS.md](DECISIONS.md) holds the behavior. Each step names the modules it adds, what it has to get right, and the tests that close it. [EXPANSION.md](EXPANSION.md) is out of scope apart from the module boundary under Layout.

## Layout

```
lua/claude-code/
  init.lua              setup() and the public API
  config.lua            defaults and validation
  events.lua            User autocmds
  terminal.lua          terminal buffers, per-terminal tokens, the active terminal
  select.lua            vim.ui.select pickers
  restore.lua           :mksession support
  editor.lua            the <C-g> endpoint
  diagnostics.lua       vim.diagnostic plus treesitter errors
  tools/init.lua        tool registry
  tools/help.lua        nvim_help, nvim_help_search, nvim_helpgrep
  server/http.lua       listener, request parsing, routing, auth
  server/ws.lua         upgrade handshake and frames
  server/sha1.lua       SHA-1 for the handshake
  server/rpc.lua        JSON-RPC dispatch with deferred replies
  server/mcp.lua        MCP methods, shared by HTTP and the websocket
  harness/claude/
    init.lua            the adapter table
    launch.lua          argv, environment, settings and MCP config files, lockfile
    hooks.lua           hook payloads into core events and state, decisions back out
    ide.lua             IDE tools and the selection sender
    diff.lua            openDiff review
    sessions.lua        transcripts, ccd's index, live sessions
bin/
  claude-code-editor        EDITOR wrapper (sh)
  claude-code-editor.cmd    EDITOR wrapper (Windows)
doc/claude-code.txt
test/
  helpers.lua
  bin/fake-claude
  fixtures/claude/      a CLAUDE_CONFIG_DIR tree
  fixtures/ccd/         a ccd session index
  fixtures/hooks/       recorded hook payloads, one file per event
  *_spec.lua
Makefile
```

Core modules never read Claude's files or payload formats. They call the adapter returned by `harness/claude/init.lua`, which follows the contract in EXPANSION.md: `launch(opts)`, `on_hook(event, payload, term)`, `sessions(filter)`, `resume(term, id)`, and `capabilities`. The IDE protocol and diff review are Claude capabilities that the adapter registers on the server. Names stay `claude-code` until a second harness exists.

## Test setup

Tests use nvim-test with the Makefile from pipe.nvim (`make test`, `FILTER=`), against stable Neovim. Specs are functional: each starts a child Neovim with `helpers.clear()` and drives it through `exec_lua`.

Real Claude never runs under `make test`. Three stand-ins replace it:

- `test/bin/fake-claude`, an `nvim -l` script that tests set as `opts.cmd`. It writes its argv, environment, and every stdin line to a JSON file named by an environment variable, and it takes scripted actions from a second file: post a hook, call an MCP tool, connect to the websocket, sleep.
- Recorded hook payloads in `test/fixtures/hooks/`, captured once from real Claude in step 6.
- A `CLAUDE_CONFIG_DIR` fixture tree with transcripts, subagents, file history, and live session files, plus a ccd index directory set through config. The plugin reads `CLAUDE_CONFIG_DIR` the way Claude does and falls back to `~/.claude`.

`test/helpers.lua` holds an HTTP client and a websocket client on `vim.uv`. The websocket client encodes masked frames with `server/ws.lua`. It also holds `layout()`, which snapshots `winlayout()` and window buffers for every tab. Every spec that opens a window asserts that the snapshot outside the current window is unchanged afterwards.

Two checks sit outside `make test`. `make contract` searches the installed Claude binary for the literal names in DECISIONS.md's Sources and fails when one is missing. The manual checklist in step 16 runs against real Claude before each release and after each Claude upgrade.

Handle leaks are checked the way pipe.nvim does it: specs record every `vim.uv` handle the server creates and assert all are closed after `stop()`.

## Steps

### 1. Skeleton

`Makefile`, nvim-test, `config.lua`, and `setup()`. Validation errors name the offending key. Calling `setup()` again replaces the previous configuration without duplicating autocmds or servers.

Tests: a second `setup()` leaves one autocmd per event in the plugin's group and one listening server. A wrong type for any key raises an error naming the key.

### 2. HTTP server

`server/http.lua` listens on `127.0.0.1` port 0, so the OS picks a free port. It parses the request line and headers, reads bodies by `Content-Length` or chunked encoding, keeps connections alive, routes on method and path, and checks `Authorization: Bearer <token>` through a lookup function passed by the caller. Responses are JSON. Request bodies above a size cap are refused.

Tests:

- a request delivered one byte per TCP write, including inside the header block
- `Content-Length` and chunked bodies
- two requests on one kept-alive connection, answered in order
- 401 for a missing or unknown token, 404 for an unknown path, 405 for a wrong method, 413 above the cap
- a handler that raises produces a 500, and the next request still succeeds
- `stop()` closes the listener and every client handle

Before moving on, point one real HTTP hook at the server with raw-request logging, and record in DECISIONS.md how Claude frames the body and whether it reuses connections.

### 3. Websocket

`server/ws.lua` upgrades `GET` requests carrying `Upgrade: websocket` and checks `X-Claude-Code-Ide-Authorization` against the lockfile token. Frame parsing and building are adapted from claudecode.nvim's `server/frame.lua`, and SHA-1 from its `server/utils.lua` (MIT, commit `2390c6e`, credited in each file's header). Fragmented messages are refused with close code 1003, as claudecode.nvim does.

Tests:

- SHA-1 against the FIPS 180 vectors: `""`, `"abc"`, and one million `"a"`
- the accept key for RFC 6455's sample key: `dGhlIHNhbXBsZSBub25jZQ==` gives `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`
- masked text frames with 7-bit, 16-bit, and 64-bit lengths, split across TCP reads
- a ping gets a pong, and a close gets a close followed by shutdown
- an unmasked client frame closes with 1002, and a continuation frame with 1003
- a missing or wrong token is refused with 401 before the upgrade

### 4. JSON-RPC and MCP

`server/rpc.lua` holds one dispatcher, and `server/mcp.lua` registers `initialize`, `notifications/initialized`, `ping`, `tools/list`, and `tools/call` on it. `POST /mcp` and websocket text frames both feed it. A handler returns a value, raises, or returns a deferred reply (a function that receives `resolve`), which `openDiff` needs. Pending replies live on the connection, and closing the connection drops them.

MCP over HTTP returns JSON only. `GET /mcp` answers 405, since the server never opens a stream. `initialize` issues an `Mcp-Session-Id`, and later requests must carry it.

Tests:

- parse error, invalid request, and unknown method return the JSON-RPC codes
- a notification gets no reply
- a deferred reply resolves after later requests were already answered
- closing a connection with pending deferred replies raises nothing
- a request over HTTP and the same request over the websocket give identical results (table-driven)
- a missing or unknown `Mcp-Session-Id` after `initialize` is refused

Step 16 checks whether Claude re-reads `tools/list` during a session. JSON-only HTTP can't push `notifications/tools/list_changed`. If Claude caches the list, DECISIONS.md's statement that tools registered mid-session appear without a restart needs correcting.

### 5. Terminals and launch

`terminal.lua` opens the terminal in the current window or in a split built from `mods` with `nvim_cmd`, defines `:Claude`, gives each terminal a token, and keeps the registry of terminals. `harness/claude/launch.lua` builds the command and environment and writes the files Claude reads.

Secrets never go in argv, because argv becomes the terminal's buffer name, gets written into session files, and shows in `ps`. The token travels only in the environment (`CLAUDE_NVIM_TOKEN`), and the port in `CLAUDE_CODE_SSE_PORT`. The hook settings and MCP config are written as files under `stdpath('run')` and passed by path. Hook headers reference `$CLAUDE_NVIM_TOKEN`. MCP config headers need the same environment variable expansion. Check it against the binary first, and if `--mcp-config` doesn't expand them, write one config file per terminal with mode 0600.

The lockfile at `$CLAUDE_CONFIG_DIR/ide/<port>.lock` (or `~/.claude/ide/`) is written atomically (temporary file, then rename) with mode 0600 when the server starts. It is removed on `VimLeavePre` and on `stop()`.

Tests with fake-claude:

- the recorded argv holds the user's `opts.cmd` flags in order, followed by `--settings <path>` and `--mcp-config <path>`
- the recorded environment has `CLAUDE_CODE_SSE_PORT`, `CLAUDE_NVIM_TOKEN`, `EDITOR`, and `FORCE_CODE_TERMINAL=true`
- `no_proxy` and `NO_PROXY` keep their existing values and gain `127.0.0.1` and `localhost` once each
- the buffer name, argv, and settings files contain no token
- `open()` without `mods` replaces the current window's buffer and nothing else
- `:Claude`, `:vertical Claude`, `:tab Claude`, and `:botright Claude` produce the same layout as `:split`, `:vertical split`, `:tab split`, and `:botright split` with `'splitright'` and `'splitbelow'` both on and both off, and the layout snapshot of other tabs is unchanged
- `open({ mods = ... })` and `:Claude` with the same modifiers produce the same layout
- two terminals get different tokens, and a request with each token resolves to its own `bufnr`
- wiping a terminal buffer unregisters its token, and later requests with it get a 401
- the lockfile's fields and mode, and its removal on `stop()`

### 6. Hooks and events

Capture fixtures first. A script in `test/` launches real Claude with a logging HTTP hook on every event from DECISIONS.md, runs a short scripted prompt that reads, edits, starts a subagent, and runs a background Bash command, and saves one payload per event (and per SessionStart `source`) into `test/fixtures/hooks/`.

`harness/claude/hooks.lua` serves `POST /hooks/<Event>`, maps the token to its terminal, updates state, fires events through `events.lua`, and calls `opts.hooks.<Event>`. A callback's return value is sent as the hook response, and an empty object is sent otherwise. A callback that raises is reported with `vim.notify`, and Claude receives the empty object so it carries on.

Tests, driven by the fixtures:

- `SessionStart` binds the session to the terminal and fires `ClaudeSessionEnter`
- a second `SessionStart` with a new id (sources `resume` and `clear`) fires `ClaudeSessionLeave` for the old session, then `ClaudeSessionEnter` for the new one
- `PreToolUse` and `PostToolUse` on Read, Edit, Write, and NotebookEdit fire `ClaudeToolUsePre` and `ClaudeToolUsePost`, add the file to `touched()`, and fire `ClaudeFilesChanged` only when the list grows
- a background Bash call fires `ClaudeSubtaskOpen`, and `SubagentStart` and `SubagentStop` fire `ClaudeSubtaskOpen` and `ClaudeSubtaskClose`
- `UserPromptSubmit`, `Stop`, and `Notification` set busy, idle, and waiting, and `ClaudeStatusChanged` fires only on a change
- `SessionEnd` fires `ClaudeSessionLeave`
- every event's `ev.data` carries `session_id` and `bufnr`
- a callback's deny decision reaches the response unchanged, and a raising callback yields `{}` plus one notification

### 7. Diagnostics and IDE tools

`diagnostics.lua` collects `vim.diagnostic.get()` and treesitter `ERROR` and `MISSING` nodes for loaded buffers. `harness/claude/ide.lua` formats them as `getDiagnostics` replies and serves `executeCode` when enabled. `executeCode` runs the code with `load`, returns the inspected return values as text, and returns errors as `isError` results.

Tests:

- diagnostics set with `vim.diagnostic.set` come back with severity names and 0-based ranges
- a Lua buffer containing `local x = (` reports treesitter errors with source `treesitter`, and a buffer with no parser reports none
- a `uri` for an unloaded file returns an empty list without an error
- a call without arguments covers loaded buffers only
- `executeCode` is missing from `tools/list` until enabled, returns values, and reports errors as `isError`
- `tools/list` over the websocket holds only the IDE tools, and custom tools appear only over `/mcp`

### 8. Selection

`harness/claude/ide.lua` sends `selection_changed` on `WinLeave` from windows showing a file (`'buftype'` empty) and on `ModeChanged` out of visual mode. The visual range comes from `'<` and `'>`. It also provides `send_selection()` and `send_at_mention(range)`. Until the open question on mapping a connection to its terminal is settled, messages go to every connected websocket.

Tests, using the websocket test client:

- leaving a file window sends `filePath` and the cursor position, without text
- leaving characterwise, linewise, and blockwise visual mode sends the selected text with 0-based positions
- leaving a Claude terminal, a help buffer, or a scratch buffer sends nothing
- nothing is sent when automatic sending is disabled
- `send_at_mention` sends 0-based `lineStart` and `lineEnd`

### 9. Diff review

The implementation to start from is an open question in DECISIONS.md, and the window layout is chosen together with it, under the principles. The protocol behavior is fixed either way. `openDiff` stays pending until the proposed buffer is written with `:w`, which replies `FILE_SAVED` plus the buffer's contents (keeping the final newline according to `'eol'`), or until the proposed buffer is deleted or shown in no window, which replies `DIFF_REJECTED` plus the tab name. `close_tab` and `closeAllDiffTabs` remove only the plugin's own diff windows and buffers. A client disconnect rejects its pending diffs.

Tests:

- accepting with `:w` returns the edited buffer, including edits the user made
- `:q` on the proposed window, `:bdelete`, and `:tabclose` each reject exactly once
- a second `openDiff` with the same `tab_name` rejects the first
- a diff for a new file, where the old path doesn't exist
- a disconnect while pending
- the layout snapshot outside the diff's own windows is unchanged

### 10. Custom tools

`tools/init.lua` registers tools from `opts.tools` and `tool(name, spec)`, maps the request token to `ctx` (`session_id`, `bufnr`), and turns handler results into MCP content: a string becomes text, and a table becomes JSON text. A handler that raises produces an `isError` result.

`tools/help.lua` finds help tags with `taglist()` in help files and reads them directly. `nvim_help(tag)` returns the text from the tag to the next tag. `nvim_help_search(pattern)` matches tag names. `nvim_helpgrep(pattern)` scans the help files on `'runtimepath'` itself, because `:helpgrep` would overwrite the user's quickfix list. Search and grep results are capped.

Tests:

- a tool registered after `initialize` appears in the next `tools/list`
- with two terminals, each call's `ctx` matches the calling terminal
- `nvim_help('nvim_buf_get_lines()')` returns that section and stops before the next tag
- an unknown tag returns `isError` with the closest tag names
- search and grep include a fixture plugin's `doc/` added to `'runtimepath'`, and stop at the cap
- the quickfix list is identical before and after `nvim_helpgrep`

### 11. Session data

`harness/claude/sessions.lua` feeds the core's `sessions(filter)` iterator. Directory listing and `fs_stat` supply `id` and `last_activity`, with no parsing. A `cwd` filter picks the project directory from the slug before any file is opened. `cwd` and `title` come from reading the start of the transcript only until they're found, up to a byte cap. The title comes first from ccd's index, then from `custom-title` or `agent-name` records, then from the first user prompt. The ccd index is scanned once per call into a table keyed by `cliSessionId`. Live state comes from `sessions/<pid>.json` after checking that the PID is alive, and `bufnr` from the terminal registry. Lines that fail to parse are skipped.

`subtasks(session)` reads `<id>/subagents/*.meta.json` and background Bash calls in the transcript. `touched(session)` reads Read, Edit, Write, and NotebookEdit calls and `file-history-*` records, and merges live hook state.

Tests, on the fixture tree:

- sessions titled by ccd, by `custom-title`, and by first prompt only, an archived one, one live (the test's own PID), and one with a dead PID
- a `cwd` filter opens no file outside that project, checked by wrapping the read function
- reading a title from a generated 50 MB transcript stops at the byte cap
- `touched()` from a transcript matches `touched()` built from the recorded hooks of the same session. Not written yet: it needs the real transcript of the hook-capture session, and auto mode refused to copy it into `test/fixtures/`. Ask Emilia whether to commit it (attachments stripped, home and user scrubbed as `capture-hooks.lua` does) or drop the test.
- malformed JSON lines are skipped without an error

`make bench` generates 1000 sessions with 1 MB transcripts and times `sessions()` for all fields and for a single project. Set the budgets after the first run, then keep the bench as a regression check.

### 12. Switching and pickers

`init.lua` resolves the active terminal: the one Claude terminal shown, otherwise the `bufnr` given or the resolver in config, otherwise an error. `switch(bufnr?, id, { new? })` sends `/resume <id>` and Enter through `chansend`. With `new = true` it opens a terminal in the current window using the harness's resume arguments (`--resume <id>`). `on_busy` reads the terminal's status. `select.lua` offers sessions for the current `cwd`, subtasks, and touched files through `vim.ui.select` with a `format_item`.

Tests:

- with one Claude terminal shown the call targets it, and with none or two it raises unless given a `bufnr` or a resolver
- an idle switch sends exactly `/resume <id>` and Enter, according to fake-claude's stdin record
- `on_busy`: `error` raises, `interrupt` sends Esc before the resume, `queue` waits for the next idle status, and `prompt` offers the choices through `vim.ui.select`
- `new = true` changes only the current window's buffer, and the old terminal keeps running in another tab
- each picker passes items and a `format_item` to a stubbed `vim.ui.select`, and choosing an item runs its action

### 13. Session restore

Start with a spike, because Neovim restores `term://` buffers through its own `BufReadCmd`. Find out whether the plugin's handler can run in place of Neovim's for its own terminals, and which one runs first. Then decide how to relaunch a terminal with a fresh token and port. Record the result in DECISIONS.md before building. Launch arguments hold file paths, not the port or token, so a stale command line is harmless as long as the plugin relaunches the terminal.

`restore.lua` then writes `stdpath('state')/claude-code/terminals.json` on `SessionWritePost`, relaunches restored Claude terminals with `--resume <id>`, and purges entries older than `opts.restore.max_age`. The spike's result is in DECISIONS.md.

Tests:

- open a fake-claude terminal bound to a session, `:mksession`, start a new child Neovim, and source the file: fake-claude is relaunched once and receives `/resume <id>`, and the state file holds the new buffer name
- the same, with `:mksession` writing to a temporary path and the file moved afterwards, as `lua/session.lua` does
- a restored plain `:terminal` is left to Neovim
- entries past `max_age` are removed on the next write
- restoring twice from the same session file with the entry already re-keyed starts a new conversation (no stale resume), with a notification

### 14. Prompt editor

`bin/claude-code-editor` posts the draft's path to `http://127.0.0.1:$CLAUDE_CODE_SSE_PORT/editor` with `curl`, authenticated with `CLAUDE_NVIM_TOKEN`, and waits for the reply. `editor.lua` opens the file through `opts.editor.open(file)` (default: `:split`, honoring `'splitbelow'`) and replies once the buffer is hidden or deleted. The `.cmd` variant does the same on Windows.

Tests:

- running the wrapper from a test job blocks until the buffer is hidden, exits 0, and leaves the edited contents in the file
- a bad token makes the wrapper exit non-zero without opening anything
- `opts.editor.open` receives the path
- the layout snapshot of other tabs is unchanged

### 15. Contract check and help file

`make contract` runs `strings -n 6` on the installed binary and checks for each literal in DECISIONS.md's Sources, printing the missing ones. Skip literals marked as minified names. Rewrite `method:R("selection_changed")` as `("selection_changed")` and `type:R("http")` as `allowedEnvVars` first, since `R` is a minified name that changes per build. All other Sources literals are present in 2.1.282. `doc/claude-code.txt` documents setup, the API, events, and options.

### 16. Manual checklist with real Claude

Run each release, and after each Claude upgrade:

- `/ide` shows Neovim connected, and `/mcp` lists the `nvim` server and its tools
- every hook in DECISIONS.md reaches the server, with the token mapping to the right terminal
- a tool registered mid-session is callable without a restart, or DECISIONS.md is corrected
- an edit triggers `getDiagnostics` before and after, and a syntax error introduced by the edit is reported back to the model
- `openDiff` accept, accept with the user's changes, and reject behave as in step 9
- a selection and a moved cursor are attached to the next prompt
- `<C-g>` opens the draft in Neovim, and the edited text comes back as the prompt
- `switch`, both in place and with `new = true`. The in-place path types `/resume <id>`, then Enter after `terminal.submit_delay` (100 ms), on the unverified assumption that Enter arriving with the text is read as a pasted newline. `on_busy = 'interrupt'` sends Esc and waits the same delay. Adjust both if Claude misreads them.
- quit Neovim with two Claude terminals, restart from the session, and both conversations resume
- with `http_proxy` set, hooks and MCP still reach the server
