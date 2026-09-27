local diagnostics = require('bodging.diagnostics')

local M = {}

local severity_names = { 'Error', 'Warning', 'Info', 'Hint' }

--- The `getDiagnostics` reply: a JSON list of `{ uri, diagnostics }` with LSP-style
--- 0-based ranges. `uri` is `file://` plus the raw path, the form Claude sends.
--- @param args { uri?: string }
--- @return table
local function get_diagnostics(args)
  local bufnr
  if args.uri then
    bufnr = diagnostics.loaded_buffer((args.uri:gsub('^file://', '')))
    if not bufnr then
      -- Claude asks before every edit, including files that were never opened
      return { content = { { type = 'text', text = '[]' } } }
    end
  end

  local files = {}
  for _, file in ipairs(diagnostics.collect(bufnr)) do
    local items = {}
    for _, d in ipairs(file.diagnostics) do
      items[#items + 1] = {
        message = d.message,
        severity = severity_names[d.severity] or 'Info',
        source = d.source,
        code = d.code and tostring(d.code) or nil,
        range = {
          start = { line = d.lnum, character = d.col },
          ['end'] = { line = d.end_lnum, character = d.end_col },
        },
      }
    end
    -- echo the requested uri: Claude drops a reply whose path differs from its request
    files[#files + 1] = { uri = args.uri or ('file://' .. file.path), diagnostics = items }
  end
  return { content = { { type = 'text', text = vim.json.encode(files) } } }
end

--- @param args { code: string }
--- @return table
local function execute_code(args)
  local chunk, err = load(args.code, '=executeCode')
  if not chunk then
    return { content = { { type = 'text', text = err } }, isError = true }
  end
  local res = vim.F.pack_len(pcall(chunk))
  if not res[1] then
    return { content = { { type = 'text', text = tostring(res[2]) } }, isError = true }
  end
  local parts = {}
  for i = 2, res.n do
    parts[#parts + 1] = vim.inspect(res[i])
  end
  return { content = { { type = 'text', text = #parts > 0 and table.concat(parts, '\n') or 'nil' } } }
end

--- Open IDE websocket connections. Selections go to all of them, since the shared lockfile
--- token can't tell which terminal a connection belongs to.
--- @type table<bodging.ws.Conn, true>
M.clients = {}

--- @param method string
--- @param params table
local function notify(method, params)
  local msg = vim.json.encode({ jsonrpc = '2.0', method = method, params = params })
  for ws in pairs(M.clients) do
    ws:send(msg)
  end
end

--- @param bufnr integer
local function is_file(bufnr)
  return vim.bo[bufnr].buftype == '' and vim.api.nvim_buf_get_name(bufnr) ~= ''
end

local visual_modes = { v = true, V = true, ['\22'] = true }

--- `selection_changed` params for the region between two `getpos()` positions, in either
--- order. Claude reads only the line numbers and treats an end at character 0 as
--- excluding that line.
--- @param from integer[]
--- @param to integer[]
--- @param mode string
--- @return table
local function region(from, to, mode)
  local pos = vim.fn.getregionpos(from, to, { type = mode })
  local text = vim.fn.getregion(from, to, { type = mode })
  local first, last = pos[1][1], pos[#pos][2]
  local finish = mode == 'V' and { line = last[2], character = 0 }
    or { line = last[2] - 1, character = last[3] }
  local path = vim.api.nvim_buf_get_name(0)
  return {
    text = table.concat(text, '\n'),
    filePath = path,
    fileUrl = 'file://' .. path,
    selection = {
      start = { line = first[2] - 1, character = math.max(first[3] - 1, 0) },
      ['end'] = finish,
      isEmpty = false,
    },
  }
end

--- `selection_changed` params for the cursor, which Claude shows as the open file.
--- @return table
local function cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local path = vim.api.nvim_buf_get_name(0)
  local at = { line = row - 1, character = col }
  return {
    filePath = path,
    fileUrl = 'file://' .. path,
    selection = { start = at, ['end'] = at, isEmpty = true },
  }
end

--- Where the last visual selection was sent from, so leaving the window right after it
--- doesn't replace it with the cursor.
--- @type { bufnr: integer, tick: integer, cursor: integer[] }?
local last_visual

--- The live visual selection in visual mode, otherwise the last one from `'<` and `'>`.
--- @return table?
local function visual()
  local mode = vim.api.nvim_get_mode().mode
  if visual_modes[mode] then
    return region(vim.fn.getpos('v'), vim.fn.getpos('.'), mode)
  end
  mode = vim.fn.visualmode()
  if visual_modes[mode] and vim.fn.getpos("'<")[2] > 0 then
    return region(vim.fn.getpos("'<"), vim.fn.getpos("'>"), mode)
  end
end

local function send_visual()
  local params = visual()
  if params then
    notify('selection_changed', params)
    local bufnr = vim.api.nvim_get_current_buf()
    last_visual = {
      bufnr = bufnr,
      tick = vim.b[bufnr].changedtick,
      cursor = vim.api.nvim_win_get_cursor(0),
    }
  end
end

local function on_win_leave()
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_file(bufnr) then
    return
  end
  if visual_modes[vim.api.nvim_get_mode().mode] then
    return send_visual()
  end
  local lv = last_visual
  if
    lv
    and lv.bufnr == bufnr
    and lv.tick == vim.b[bufnr].changedtick
    and vim.deep_equal(lv.cursor, vim.api.nvim_win_get_cursor(0))
  then
    return
  end
  notify('selection_changed', cursor())
end

--- Sends the current visual selection, or the last one in this buffer.
function M.send_selection()
  if not is_file(0) then
    error('bodging: the current buffer is not a file', 0)
  end
  notify('selection_changed', visual() or cursor())
end

--- Mentions the current file in Claude's prompt, optionally with a line range.
--- @param range? integer[] first and last line, 1-based
function M.send_at_mention(range)
  if not is_file(0) then
    error('bodging: the current buffer is not a file', 0)
  end
  notify('at_mentioned', {
    filePath = vim.api.nvim_buf_get_name(0),
    lineStart = range and range[1] - 1,
    lineEnd = range and range[2] - 1,
  })
end

--- Sends `selection_changed` automatically while `opts.selection.auto` is set.
--- @param group integer
function M.attach(group)
  local function auto(fn)
    return function()
      if next(M.clients) and require('bodging.harness.claude.config').current().selection.auto then
        fn()
      end
    end
  end
  vim.api.nvim_create_autocmd('WinLeave', { group = group, callback = auto(on_win_leave) })
  vim.api.nvim_create_autocmd('ModeChanged', {
    group = group,
    -- one pattern, since patterns ignore case where 'fileignorecase' is on (macOS)
    pattern = '[vV\22]:*',
    callback = auto(function()
      local new = vim.v.event.new_mode
      if not visual_modes[new:sub(1, 1)] and is_file(0) then
        send_visual()
      end
    end),
  })
end

--- Tools served on the IDE websocket.
--- @return bodging.mcp.Tool[]
function M.tools()
  local tools = {
    {
      name = 'getDiagnostics',
      description = 'Get diagnostics (errors, warnings) from Neovim for a file, or for all loaded files',
      input_schema = {
        type = 'object',
        properties = { uri = { type = 'string', description = 'file:// URI; omit for all loaded files' } },
      },
      handler = get_diagnostics,
    },
    {
      name = 'openDiff',
      description = 'Show proposed file contents for review, and wait for the user to accept or reject them',
      input_schema = {
        type = 'object',
        properties = {
          old_file_path = { type = 'string' },
          new_file_path = { type = 'string' },
          new_file_contents = { type = 'string' },
          tab_name = { type = 'string' },
        },
        required = { 'old_file_path', 'new_file_path', 'new_file_contents', 'tab_name' },
      },
      handler = function(args)
        return function(resolve)
          local d = require('bodging.harness.claude.diff').open(args, resolve)
          return function()
            require('bodging.harness.claude.diff').cancel(d)
          end
        end
      end,
    },
    {
      name = 'close_tab',
      description = 'Close a diff opened by openDiff',
      input_schema = {
        type = 'object',
        properties = { tab_name = { type = 'string' } },
        required = { 'tab_name' },
      },
      handler = function(args)
        require('bodging.harness.claude.diff').close(args.tab_name)
        return 'TAB_CLOSED'
      end,
    },
    {
      name = 'closeAllDiffTabs',
      description = 'Close every diff opened by openDiff',
      handler = function()
        return ('CLOSED_%d_DIFF_TABS'):format(require('bodging.harness.claude.diff').close_all())
      end,
    },
  }
  if require('bodging.harness.claude.config').current().execute_code then
    tools[#tools + 1] = {
      name = 'executeCode',
      description = "Run Lua in the user's Neovim and return the inspected return values",
      input_schema = {
        type = 'object',
        properties = {
          code = { type = 'string', description = 'Lua chunk; use return to get values back' },
        },
        required = { 'code' },
      },
      handler = execute_code,
    }
  end
  return tools
end

return M
