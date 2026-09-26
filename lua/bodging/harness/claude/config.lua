local M = {}

--- @class bodging.claude.Config
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
      return require('bodging.terminal').pick_window()
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
