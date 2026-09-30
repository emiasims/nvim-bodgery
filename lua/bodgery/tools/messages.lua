local M = {}

--- The message history as `:messages` shows it, or the `count` most recent messages.
--- @param count? integer
--- @return string
function M.messages(count)
  local cmd = count and ('%dmessages'):format(count) or 'messages'
  return vim.api.nvim_exec2(cmd, { output = true }).output
end

--- @type bodgery.ToolSpec
M.tool = {
  description = "Returns the user's Neovim message history as `:messages` shows it: errors, "
    .. 'warnings, and echoed messages, oldest first, including ones already gone from the '
    .. 'command line. `count` keeps only the most recent ones.',
  input_schema = {
    type = 'object',
    properties = { count = { type = 'integer', minimum = 1 } },
  },
  handler = function(args)
    local text = M.messages(args.count)
    return text == '' and 'no messages' or text
  end,
}

return M
