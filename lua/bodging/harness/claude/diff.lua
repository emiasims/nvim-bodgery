local M = {}

local ns = vim.api.nvim_create_namespace('bodging.diff')

--- @class bodging.Diff
--- @field tab_name string
--- @field path string
--- @field bufnr integer the proposed buffer
--- @field win integer
--- @field created boolean the window was opened for this diff
--- @field prev? integer the buffer the window showed before
--- @field old string[]
--- @field resolve fun(result: table)
--- @field done boolean

--- Open diffs by tab name.
--- @type table<string, bodging.Diff>
M.pending = {}

--- @param text string
--- @return string[] lines
--- @return boolean eol
local function split(text)
  if text == '' then
    return {}, false
  end
  local eol = text:sub(-1) == '\n'
  return vim.split(eol and text:sub(1, -2) or text, '\n', { plain = true }), eol
end

--- @param lines string[]
--- @return string
local function join(lines)
  return #lines == 0 and '' or table.concat(lines, '\n') .. '\n'
end

--- @param status string
--- @param text string
--- @return table
local function result(status, text)
  return { content = { { type = 'text', text = status }, { type = 'text', text = text } } }
end

--- Byte offset of each character's start in `chars`, 0-based, plus one past the end.
--- @param chars string[]
--- @return integer[]
local function offsets(chars)
  local out, pos = {}, 0
  for i, c in ipairs(chars) do
    out[i] = pos
    pos = pos + #c
  end
  out[#chars + 1] = pos
  return out
end

--- Marks a changed line: inserted characters highlighted, removed ones shown inline.
--- @param bufnr integer
--- @param row integer 0-based
--- @param old string
--- @param new string
local function render_inline(bufnr, row, old, new)
  -- a range to the line's end, since line_hl_group draws over every hl_group in the line
  vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
    end_row = row + 1,
    hl_group = 'DiffChange',
    hl_eol = true,
    priority = vim.hl.priorities.user - 1,
  })
  local a, b = vim.fn.split(old, [[\zs]]), vim.fn.split(new, [[\zs]])
  local off = offsets(b)
  local hunks = vim.text.diff(join(a), join(b), { result_type = 'indices' }) --[[@as integer[][] ]]
  for _, hunk in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    if count_b > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, off[start_b], {
        end_col = off[start_b + count_b],
        hl_group = 'DiffText',
      })
    end
    if count_a > 0 then
      -- a pure deletion's start_b is the character before it
      local col = count_b > 0 and off[start_b] or off[start_b + 1]
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, {
        virt_text = { { table.concat(a, '', start_a, start_a + count_a - 1), 'DiffDelete' } },
        virt_text_pos = 'inline',
      })
    end
  end
end

--- Highlights added lines and shows removed ones as virtual lines where they were. With
--- `opts.diff.inline`, a changed line that pairs with its old version is marked inline.
--- @param d bodging.Diff
local function render(d)
  vim.api.nvim_buf_clear_namespace(d.bufnr, ns, 0, -1)
  local inline = require('bodging.harness.claude.config').current().diff.inline
  local new = vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false)
  local hunks = vim.text.diff(join(d.old), join(new), {
    result_type = 'indices',
    -- splits hunks so that paired lines come back as hunks of equal size
    linematch = inline and 40 or nil,
  }) --[[@as integer[][] ]]
  local width = vim.o.columns
  for _, hunk in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    if inline and count_a == count_b then
      for k = 0, count_a - 1 do
        render_inline(d.bufnr, start_b - 1 + k, d.old[start_a + k], new[start_b + k])
      end
    else
      for row = start_b - 1, start_b + count_b - 2 do
        vim.api.nvim_buf_set_extmark(d.bufnr, ns, row, 0, { line_hl_group = 'DiffAdd' })
      end
      if count_a > 0 then
        local virt = {}
        for i = start_a, start_a + count_a - 1 do
          local text = d.old[i]:gsub('\t', (' '):rep(vim.bo[d.bufnr].tabstop))
          virt[#virt + 1] = { { text .. (' '):rep(width - vim.fn.strdisplaywidth(text)), 'DiffDelete' } }
        end
        -- a pure deletion's start_b is the line before it
        local row, above = start_b - 1, count_b > 0
        if count_b == 0 and start_b == 0 then
          row, above = 0, true
        end
        vim.api.nvim_buf_set_extmark(d.bufnr, ns, row, 0, {
          virt_lines = virt,
          virt_lines_above = above,
        })
      end
    end
  end
end

--- Resolves `d` once, then puts its window back and removes the proposed buffer.
--- @param d bodging.Diff
--- @param res? table nil drops the reply, as on a disconnect
local function finish(d, res)
  if d.done then
    return
  end
  d.done = true
  if M.pending[d.tab_name] == d then
    M.pending[d.tab_name] = nil
  end
  if res then
    d.resolve(res)
  end
  -- deferred, since this can run inside the buffer's own BufWriteCmd or BufWipeout
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(d.win) and vim.api.nvim_win_get_buf(d.win) == d.bufnr then
      if d.created and #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(d.win, true)
      elseif d.prev and vim.api.nvim_buf_is_valid(d.prev) then
        vim.api.nvim_win_set_buf(d.win, d.prev)
      end
    end
    if vim.api.nvim_buf_is_valid(d.bufnr) then
      vim.api.nvim_buf_delete(d.bufnr, { force = true })
    end
  end)
end

--- @param path string
--- @return string
local function read(path)
  local f = io.open(path, 'rb')
  if not f then
    return ''
  end
  local text = f:read('*a')
  f:close()
  return text
end

--- @class bodging.OpenDiffArgs
--- @field old_file_path string
--- @field new_file_path string
--- @field new_file_contents string
--- @field tab_name string

--- Shows Claude's proposed contents in one window. `:w` accepts them, with any edits the
--- user made, and deleting or hiding the buffer rejects them.
--- @param args bodging.OpenDiffArgs
--- @param resolve fun(result: table)
--- @return bodging.Diff
function M.open(args, resolve)
  local path = args.new_file_path
  for _, other in pairs(M.pending) do
    if other.tab_name == args.tab_name or other.path == path then
      finish(other, result('DIFF_REJECTED', other.tab_name))
    end
  end

  local lines, eol = split(args.new_file_contents)
  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local bo = vim.bo[bufnr]
  bo.buftype = 'acwrite'
  -- hiding the buffer anywhere rejects the diff through BufWipeout
  bo.bufhidden = 'wipe'
  bo.swapfile = false
  bo.eol = eol or #lines == 0
  bo.fixeol = false
  bo.filetype = vim.filetype.match({ filename = path }) or ''
  -- unique while a previous diff of the same file waits for its scheduled cleanup
  local name = 'bodging://' .. path
  if vim.fn.bufexists(name) == 1 then
    name = ('%s (%d)'):format(name, bufnr)
  end
  vim.api.nvim_buf_set_name(bufnr, name)
  bo.modified = false

  local before = vim.api.nvim_list_wins()
  local win = require('bodging.harness.claude.config').current().diff.window()
  local created = not vim.list_contains(before, win)
  local d = {
    tab_name = args.tab_name,
    path = path,
    bufnr = bufnr,
    win = win,
    created = created,
    prev = not created and vim.api.nvim_win_get_buf(win) or nil,
    old = split(read(args.old_file_path)),
    resolve = resolve,
    done = false,
  }
  M.pending[args.tab_name] = d
  vim.api.nvim_win_set_buf(win, bufnr)

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = bufnr,
    callback = function()
      local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
      if vim.bo[bufnr].eol then
        text = text .. '\n'
      end
      vim.bo[bufnr].modified = false
      finish(d, result('FILE_SAVED', text))
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function()
      finish(d, result('DIFF_REJECTED', d.tab_name))
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = bufnr,
    callback = function()
      render(d)
    end,
  })
  render(d)

  local first = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { limit = 1 })[1]
  if first then
    vim.api.nvim_win_set_cursor(win, { first[2] + 1, 0 })
  end
  return d
end

--- Closes the diff for `tab_name`, which Claude does once the user answered in the terminal.
--- @param tab_name string
function M.close(tab_name)
  local d = M.pending[tab_name]
  if d then
    finish(d, result('TAB_CLOSED', tab_name))
  end
end

--- @return integer closed
function M.close_all()
  local n = 0
  for _, d in pairs(M.pending) do
    finish(d, result('TAB_CLOSED', d.tab_name))
    n = n + 1
  end
  return n
end

--- Closes `d` without replying, for a client that disconnected.
--- @param d bodging.Diff
function M.cancel(d)
  finish(d)
end

return M
