local M = {}

--- @class bodgery.claude.Config
--- @field hooks table<string, fun(input: table): table?> hook event name to callback
--- @field execute_code boolean serve the `executeCode` IDE tool
--- @field selection { auto: boolean } send `selection_changed` automatically
--- @field diff { window: fun(): integer, inline: boolean } `window` picks where a proposed edit shows, `inline` marks changes within a line
--- @field ccd_dir string root of ccd's session index
M.defaults = {
  cmd = { 'claude' },
  hooks = {},
  execute_code = false,
  selection = { auto = true },
  diff = {
    inline = true,
    window = function()
      return require('bodgery.terminal').pick_window()
    end,
  },
  ccd_dir = vim.fs.normalize('~/Library/Application Support/Claude/claude-code-sessions'),
}

-- sorted so a parent table is checked before its fields
M.schema = {
  { 'ccd_dir', 'string' },
  { 'diff', 'table' },
  { 'diff.inline', 'boolean' },
  { 'diff.window', 'function' },
  { 'execute_code', 'boolean' },
  { 'hooks', 'table' },
  { 'selection', 'table' },
  { 'selection.auto', 'boolean' },
}

M.hook_events = {
  'SessionStart',
  'PreToolUse',
  'PostToolUse',
  'SubagentStart',
  'SubagentStop',
  'UserPromptSubmit',
  'Stop',
  'Notification',
  'SessionEnd',
}

--- Whether `claude` is on the path and has a config directory.
--- @return boolean
function M.detect()
  local dir = vim.env.CLAUDE_CONFIG_DIR or vim.fs.normalize('~/.claude')
  return vim.fn.executable('claude') == 1 and vim.fn.isdirectory(dir) == 1
end

--- The config of the most recently used Claude terminal, for IDE requests, which can't
--- tell which terminal sent them. The defaults when none is open.
--- @return bodgery.claude.Config
function M.current()
  local term = require('bodgery.terminal').last('claude')
  return term and term.config or M.defaults
end

--- Checks what `schema` can't express, after it has passed.
--- @param opts table
--- @param fail fun(fmt: string, ...)
--- @param expect fun(name: string, value: any, expected: string, optional?: boolean)
function M.validate(opts, fail, expect)
  for event, callback in pairs(opts.hooks) do
    if not vim.list_contains(M.hook_events, event) then
      fail('hooks.%s: unknown hook event', event)
    end
    expect('hooks.' .. event, callback, 'function')
  end
end

return M
