local M = {}

--- Milliseconds to wait for the screen to be drawn.
M.timeout = 2000

--- @class bodgery.ScreenRun
--- @field [1] integer row, 1-based
--- @field [2] integer first screen column, 1-based
--- @field [3] integer last screen column, inclusive
--- @field [4] string highlight groups, joined with '+' when combined

--- @class bodgery.Screen
--- @field lines string[] one per screen row, trailing spaces removed
--- @field highlights? bodgery.ScreenRun[]

--- @param info table[] `ext_hlstate` info for one attribute id
--- @return string?
local function group_name(info)
  local names = {}
  for _, item in ipairs(info) do
    local name = item.ui_name or item.hi_name
    if name and not vim.list_contains(names, name) then
      names[#names + 1] = name
    end
  end
  return #names > 0 and table.concat(names, '+') or nil
end

--- @param grid { [1]: string, [2]: integer }[][] rows of `{ text, attr_id }` cells
--- @param attrs table<integer, table[]>
--- @param highlights boolean
--- @return bodgery.Screen
local function snapshot(grid, attrs, highlights)
  local out = { lines = {}, highlights = highlights and {} or nil }
  for r, row in ipairs(grid) do
    local text = {}
    for c, cell in ipairs(row) do
      text[c] = cell[1]
    end
    out.lines[r] = (table.concat(text):gsub('%s+$', ''))

    local c = 1
    while highlights and c <= #row do
      local id, last = row[c][2], c
      while last < #row and row[last + 1][2] == id do
        last = last + 1
      end
      local name = attrs[id] and group_name(attrs[id])
      if name then
        out.highlights[#out.highlights + 1] = { r, c, last, name }
      end
      c = last + 1
    end
  end
  return out
end

--- Reads the screen by attaching a UI to this Neovim's own server. Attaching forces a
--- full redraw, and `callback` runs after the first flush that drew the grid.
--- @param opts { highlights?: boolean }
--- @param callback fun(screen: bodgery.Screen?, err: string?)
--- @return fun() cancel
local function attach(opts, callback)
  local addr, started = vim.v.servername, false
  if addr == '' then
    addr, started = vim.fn.serverstart(), true
  end
  local width, height = vim.o.columns, vim.o.lines
  local ui_opts = { ext_linegrid = true, ext_hlstate = opts.highlights == true, rgb = true }
  local pipe = assert(vim.uv.new_pipe())
  local timer = assert(vim.uv.new_timer())
  local session = vim.mpack.Session({ unpack = vim.mpack.Unpacker({ ext = {} }) })
  local grid, attrs, drawn, done = {}, {}, false, false

  local function finish(screen, err)
    if done then
      return
    end
    done = true
    timer:close()
    pipe:close()
    vim.schedule(function()
      if started then
        vim.fn.serverstop(addr)
      end
      if screen or err then
        callback(screen, err)
      end
    end)
  end

  local handlers = {
    grid_resize = function(a)
      grid = {}
      for r = 1, a[3] do
        grid[r] = {}
        for c = 1, a[2] do
          grid[r][c] = { ' ', 0 }
        end
      end
    end,
    hl_attr_define = function(a)
      attrs[a[1]] = a[4]
    end,
    grid_line = function(a)
      drawn = true
      local row, col, id = grid[a[2] + 1], a[3] + 1, 0
      for _, cell in ipairs(a[4]) do
        id = cell[2] or id
        for _ = 1, cell[3] or 1 do
          row[col] = { cell[1], id }
          col = col + 1
        end
      end
    end,
    flush = function()
      -- the flush right after attaching only clears the grid
      if drawn then
        finish(snapshot(grid, attrs, opts.highlights))
      end
    end,
  }

  timer:start(M.timeout, 0, function()
    finish(nil, ('screen not drawn within %d ms'):format(M.timeout))
  end)
  pipe:connect(addr, function(cerr)
    if cerr then
      return finish(nil, cerr)
    end
    pipe:read_start(function(rerr, data)
      if rerr or not data then
        return finish(nil, rerr or 'server closed the connection')
      end
      local pos = 1
      while pos <= #data and not done do
        local kind, _, method, args
        kind, _, method, args, pos = session:receive(data, pos)
        if not kind then
          break
        end
        if kind == 'notification' and method == 'redraw' then
          for _, event in ipairs(args) do
            local handler = handlers[event[1]]
            for i = 2, handler and #event or 0 do
              handler(event[i])
            end
          end
        end
      end
    end)
    pipe:write(
      session:notify() .. vim.mpack.encode('nvim_ui_attach') .. vim.mpack.encode({ width, height, ui_opts })
    )
  end)

  return function()
    finish()
  end
end

local renumbered = false

--- @param opts { highlights?: boolean }
--- @param callback fun(screen: bodgery.Screen?, err: string?)
--- @return fun() cancel
function M.capture(opts, callback)
  if renumbered or not opts.highlights then
    return attach(opts, callback)
  end
  -- the first UI to attach with ext_hlstate makes Neovim renumber every highlight
  -- attribute, and highlights set with nvim_set_hl(ns, ...) keep the old numbers. Re-set
  -- them, then capture again so the snapshot shows the repaired colors.
  local saved = {}
  for _, ns in pairs(vim.api.nvim_get_namespaces()) do
    saved[ns] = vim.api.nvim_get_hl(ns, {})
  end
  local cancel
  cancel = attach(opts, function(_, err)
    for ns, hls in pairs(saved) do
      for name, hl in pairs(hls) do
        vim.api.nvim_set_hl(ns, name, hl)
      end
    end
    if err then
      return callback(nil, err)
    end
    renumbered = true
    cancel = attach(opts, callback)
  end)
  return function()
    cancel()
  end
end

--- @type bodgery.ToolSpec
M.tool = {
  description = 'Returns the Neovim screen as the user sees it: every window, the status lines, '
    .. 'tabline, and command line, one string per screen row. With highlights, also returns '
    .. 'runs of { row, first_column, last_column, group } in 1-based screen cells (a wide '
    .. 'character takes two), naming the highlight group of each run.',
  input_schema = {
    type = 'object',
    properties = { highlights = { type = 'boolean', description = 'include highlight group runs' } },
  },
  handler = function(args)
    return function(resolve)
      return M.capture({ highlights = args.highlights == true }, function(screen, err)
        if err then
          resolve({ content = { { type = 'text', text = err } }, isError = true })
        elseif args.highlights then
          resolve(screen)
        else
          resolve(table.concat(screen.lines, '\n'))
        end
      end)
    end
  end,
}

return M
