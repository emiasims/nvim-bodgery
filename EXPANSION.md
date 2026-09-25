# Other agents

Supporting agents other than Claude Code (codex, opencode, pi) would split the plugin into a core that doesn't depend on the agent and one adapter per agent. [DECISIONS.md](DECISIONS.md) holds the Claude design this builds on.

Versions checked: Claude Code 2.1.281, pi 0.87.1, opencode 1.18.32, and `openai/codex` main as of 2026-09-25. Entries marked "not checked" are unverified. [Sources](#sources) lists where each fact came from.

## Capabilities

| | Claude | codex | opencode | pi |
|---|---|---|---|---|
| Custom tools | MCP, `--mcp-config` | MCP, `-c mcp_servers.<id>.url=...` with `bearer_token_env_var` or `env_http_headers` | MCP (`type: "remote"`) through `OPENCODE_CONFIG_CONTENT` | No MCP. Extension tools (`pi -e ext.ts`, `pi.registerTool`) |
| Hooks and events | HTTP hooks | Command hooks, plus hooks that call a tool on a connected MCP server. Same event names as Claude | JS plugin: `tool.execute.before/after`, `session.*`, `file.edited`, `lsp.client.diagnostics` | Extension: `pi.on` with `tool_call`, `tool_result`, session events |
| Can block or rewrite tool calls | Yes | Yes (`PreToolUse`, `PermissionRequest`) | Yes (`tool.execute.before`) | Yes (`tool_call`) |
| Editor protocol | `--ide` websocket | None for the terminal UI. The VS Code extension uses a separate server mode (not checked) | IDE extension shares selection and tab (mechanism not checked) | None |
| Session storage | `~/.claude/projects/<slug>/<id>.jsonl`, plus ccd's index | `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`, plus a SQLite state DB | SQLite (`~/.local/share/opencode/opencode.db`). `opencode session list --format json` reads it | `~/.pi/agent/sessions/`, grouped by working directory |
| Resume by id in a running terminal | `/resume <id>` | Not checked | No. Launch with `--session <id>` | No, `/resume` opens a picker. Launch with `--session <id>` |
| Prompt in external editor | `$VISUAL`/`$EDITOR` | `$VISUAL`/`$EDITOR` (`codex-rs/tui/src/external_editor.rs`) | `/editor` uses `$EDITOR` | `ctrl+g`: `externalEditor` setting, then `$VISUAL`/`$EDITOR` |
| Per-launch config | `--settings`, `--mcp-config` | `-c key=value` (`codex-rs/utils/cli/src/config_override.rs`) | `OPENCODE_CONFIG_CONTENT`, `OPENCODE_CONFIG` | `-e <extension>`, CLI flags |

## Core

These parts work with any agent without changes: the HTTP server, the terminal buffer with its window behavior, session restore, the `EDITOR` wrapper, the tool registry, `User` events, and `vim.ui.select` pickers.

The event names and the plugin name would need a prefix that isn't tied to Claude (`ClaudeToolUsePre` becomes, for example, `AgentToolUsePre`). The rename is cheap before other code depends on those names.

## Adapter contract

Each adapter supplies:

- `launch(opts)`: the command, arguments, and environment that connect the agent's tools and events to the core's HTTP server
- event translation from the agent's hook or plugin payloads into the core's events, with `session_id` and the terminal
- `sessions()`: an iterator over the agent's own session storage
- `resume(id)`: keys to send to a running terminal where the agent supports it (Claude only), otherwise launch arguments. A relaunch goes in the current window, so `switch` still behaves like `:edit`.
- capability flags for features one agent lacks, such as the IDE protocol and resuming in place

## Per-agent notes

codex hooks run commands. Reaching the core takes `curl`, or a hook that calls a tool on the core's MCP server, which starts no process.

opencode and pi need a shipped JS or TS file: an opencode plugin, or a pi extension. pi has no MCP, so its extension fetches the tool list from the core and registers each tool with `pi.registerTool`.

## Selection and context

Only Claude accepts pushed editor state (`selection_changed` over the websocket). The others can pull context when a prompt is submitted: `UserPromptSubmit` returning `additionalContext` (codex, and Claude too), `before_agent_start` (pi), or `tui.prompt.append` (opencode). With a pull at submit time, all four could share one context function, and the websocket would become optional for Claude.

## Diff review

Only Claude asks the editor to review an edit (`openDiff`). All four can block a tool call before it runs, so one core function, `review(path, new_contents)` returning accept, reject, or edited contents, could serve Claude's `openDiff`, codex's `PreToolUse` on `apply_patch`, opencode's `tool.execute.before`, and pi's `tool_call`.

## Diagnostics

Claude pulls diagnostics before and after each edit through `getDiagnostics`. Elsewhere, the core can serve them through a tool, or return them from a post-edit hook as added context. opencode runs its own LSP clients and emits `lsp.client.diagnostics`, which can differ from what Neovim's LSP clients report.

## Recommendation

Build for Claude first. Keep hook payload parsing and session reading in their own modules, so an adapter can be added without touching the rest.

## Sources

Claude Code: see [DECISIONS.md](DECISIONS.md#sources).

pi, bundled docs under `/opt/homebrew/Cellar/pi-coding-agent/<version>/libexec/lib/node_modules/@earendil-works/pi-coding-agent/docs/`:

- `extensions.md` for `pi.on`, `pi.registerTool`, and blocking `tool_call`
- `sessions.md` for storage, `--session`, and `/resume` as a picker
- `cli-integration.md` for print, JSON, and RPC modes
- `keybindings.md`, `settings.md`, and `environment-variables.md` for `ctrl+g` and `externalEditor`
- `pi --help` for launch flags
- exact event types: <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/extensions/types.ts>

opencode:

- <https://opencode.ai/docs/plugins/> for plugin events, tool hooks, and custom tools
- <https://opencode.ai/docs/ide/> for the IDE extension and `/editor`
- <https://opencode.ai/docs/config/> for `OPENCODE_CONFIG_CONTENT` and MCP config, with the full schema at <https://opencode.ai/config.json>
- `opencode --help` and `opencode session list --help` for `--session` and `--format json`
- the SQLite store is visible at `~/.local/share/opencode/opencode.db`

codex, in <https://github.com/openai/codex>:

- `codex-rs/tui/src/external_editor.rs` for `$VISUAL`/`$EDITOR`
- `codex-rs/core/tests/suite/rollout_list_find.rs` for the `sessions/YYYY/MM/DD/rollout-*.jsonl` layout
- `codex-rs/utils/cli/src/config_override.rs` for `-c key=value`
- <https://learn.chatgpt.com/docs/hooks> for hook events, handler types, and blocking
- <https://learn.chatgpt.com/docs/config-file/config-reference> for `mcp_servers.<id>` keys and `notify`
