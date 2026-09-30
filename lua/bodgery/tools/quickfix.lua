local M = {}

--- Entries returned per call when the caller gives no `limit`.
M.default_limit = 50

--- @class bodgery.QuickfixItem
--- @field index integer 1-based position in the whole list
--- @field filename string full path, or '' for an entry without a file
--- @field module? string
--- @field lnum integer
--- @field end_lnum integer
--- @field col integer
--- @field end_col integer
--- @field type string
--- @field text string
--- @field valid boolean

--- @class bodgery.Quickfix
--- @field title string
--- @field size integer entries in the whole list
--- @field idx integer current entry, 0 when the list is empty
--- @field items bodgery.QuickfixItem[] entries `offset + 1` to `offset + limit`

--- @param opts { list?: 'quickfix'|'location', window?: integer, offset?: integer, limit?: integer }
--- @return bodgery.Quickfix
function M.get(opts)
  local what = { title = 0, size = 0, idx = 0, items = 0 }
  local info
  if opts.list == 'location' then
    local win = opts.window or vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(win) then
      error(('no window %d'):format(win), 0)
    end
    info = vim.fn.getloclist(win, what)
  else
    info = vim.fn.getqflist(what)
  end

  local offset = opts.offset or 0
  local items = {}
  for i = offset + 1, math.min(offset + (opts.limit or M.default_limit), #info.items) do
    local item = info.items[i]
    items[#items + 1] = {
      index = i,
      filename = item.bufnr > 0 and vim.api.nvim_buf_get_name(item.bufnr) or '',
      module = item.module ~= '' and item.module or nil,
      lnum = item.lnum,
      end_lnum = item.end_lnum,
      col = item.col,
      end_col = item.end_col,
      type = item.type,
      text = item.text,
      valid = item.valid == 1,
    }
  end
  return { title = info.title, size = info.size, idx = info.idx, items = items }
end

--- @type bodgery.ToolSpec
M.tool = {
  description = "Returns the user's quickfix list, or a window's location list, a page at a "
    .. 'time: its title, total size, current entry (idx), and entries offset + 1 to offset + '
    .. ('limit (default %d), each with its 1-based index, file, position, type, and text. '):format(
      M.default_limit
    )
    .. "`window` is the location list's window ID, defaulting to the current window.",
  input_schema = {
    type = 'object',
    properties = {
      list = { type = 'string', enum = { 'quickfix', 'location' } },
      window = { type = 'integer' },
      offset = { type = 'integer', minimum = 0 },
      limit = { type = 'integer', minimum = 1 },
    },
  },
  handler = function(args)
    return M.get(args)
  end,
}

return M
