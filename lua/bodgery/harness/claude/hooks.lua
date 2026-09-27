local events = require('bodgery.events')

local M = {}

local FILE_TOOLS =
  { Read = 'file_path', Edit = 'file_path', Write = 'file_path', NotebookEdit = 'notebook_path' }

--- @class bodgery.Subtask
--- @field id string
--- @field kind 'agent'|'bash'
--- @field description? string
--- @field open boolean
--- @field path? string the agent's transcript, or a finished background command's output

--- Live state from hooks, per session id.
--- @type table<string, { touched: string[], subtasks: table<string, bodgery.Subtask> }>
M.sessions = {}

--- @param id string
local function session(id)
  M.sessions[id] = M.sessions[id] or { touched = {}, subtasks = {} }
  return M.sessions[id]
end

--- @param term bodgery.Terminal
--- @param extra? table
local function data(term, extra)
  return vim.tbl_extend(
    'force',
    { session_id = term.session_id, bufnr = term.bufnr, config = term.config.name },
    extra or {}
  )
end

--- @param term bodgery.Terminal
--- @param status 'busy'|'idle'|'waiting'
local function set_status(term, status)
  if term.status ~= status then
    term.status = status
    events.fire('ClaudeStatusChanged', data(term, { status = status }))
  end
end

--- @param term bodgery.Terminal
local function leave(term)
  if term.session_id then
    events.fire('ClaudeSessionLeave', data(term))
    term.session_id = nil
  end
end

--- @param term bodgery.Terminal
--- @param subtask bodgery.Subtask
local function open_subtask(term, subtask)
  session(term.session_id).subtasks[subtask.id] = subtask
  events.fire('ClaudeSubtaskOpen', data(term, { subtask = subtask }))
end

--- @param term bodgery.Terminal
--- @param subtask bodgery.Subtask
local function close_subtask(term, subtask)
  if subtask.open then
    subtask.open = false
    events.fire('ClaudeSubtaskClose', data(term, { subtask = subtask }))
  end
end

--- Closes background Bash subtasks missing from a Stop payload's `background_tasks`.
--- @param term bodgery.Terminal
--- @param running? { id: string }[]
local function sweep_background(term, running)
  if not running then
    return
  end
  local live = {}
  for _, task in ipairs(running) do
    live[task.id] = true
  end
  for id, subtask in pairs(session(term.session_id).subtasks) do
    if subtask.kind == 'bash' and not live[id] then
      close_subtask(term, subtask)
    end
  end
end

--- @param term bodgery.Terminal
--- @param input table
local function touch(term, input)
  local key = FILE_TOOLS[input.tool_name]
  local path = key and type(input.tool_input) == 'table' and input.tool_input[key]
  if type(path) ~= 'string' then
    return
  end
  local touched = session(term.session_id).touched
  if not vim.list_contains(touched, path) then
    touched[#touched + 1] = path
    events.fire('ClaudeFilesChanged', data(term, { files = vim.deepcopy(touched) }))
  end
end

--- Turns on 'autoread' for a loaded buffer the agent is about to write, until
--- the write is read back.
--- @param input table
local function autoread(input)
  local key = input.tool_name ~= 'Read' and FILE_TOOLS[input.tool_name]
  local path = key and type(input.tool_input) == 'table' and input.tool_input[key]
  local buf = type(path) == 'string' and vim.fn.bufnr(path) or -1
  if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  -- nil when the buffer has no local value
  local local_value = vim.api.nvim_get_option_value('autoread', { buf = buf })
  if local_value or (local_value == nil and vim.o.autoread) then
    return
  end
  -- the filewatcher behind 'autoread' starts from OptionSet in the current buffer
  vim.api.nvim_buf_call(buf, function()
    vim.bo.autoread = true
  end)
  vim.api.nvim_create_autocmd('FileChangedShellPost', {
    buffer = buf,
    once = true,
    nested = true,
    callback = function()
      vim.api.nvim_buf_call(buf, function()
        vim.cmd(local_value == nil and 'set autoread<' or 'setlocal noautoread')
      end)
    end,
  })
end

--- Updates terminal state and fires events for one hook payload.
--- @param event string
--- @param input table
--- @param term bodgery.Terminal
function M.on_hook(event, input, term)
  if event == 'SessionStart' then
    if term.session_id ~= input.session_id then
      leave(term)
      term.session_id = input.session_id
      session(term.session_id)
      events.fire('ClaudeSessionEnter', data(term, { source = input.source }))
    end
    return
  end

  -- a hook from a session whose SessionStart was missed still binds it
  if not term.session_id then
    term.session_id = input.session_id
    events.fire('ClaudeSessionEnter', data(term))
  end

  if event == 'SessionEnd' then
    leave(term)
  elseif event == 'UserPromptSubmit' then
    set_status(term, 'busy')
  elseif event == 'Stop' then
    sweep_background(term, input.background_tasks)
    set_status(term, 'idle')
  elseif event == 'Notification' then
    set_status(term, input.notification_type == 'idle_prompt' and 'idle' or 'waiting')
  elseif event == 'PreToolUse' or event == 'PostToolUse' then
    set_status(term, 'busy')
    local name = event == 'PreToolUse' and 'ClaudeToolUsePre' or 'ClaudeToolUsePost'
    events.fire(
      name,
      data(term, {
        tool_name = input.tool_name,
        tool_input = input.tool_input,
        tool_response = input.tool_response,
        tool_use_id = input.tool_use_id,
      })
    )
    -- after the event, so a listener that loads the file gets 'autoread' too
    if event == 'PreToolUse' then
      autoread(input)
    end
    touch(term, input)
    local task_id = type(input.tool_response) == 'table' and input.tool_response.backgroundTaskId
    if event == 'PostToolUse' and input.tool_name == 'Bash' and task_id then
      local tool_input = input.tool_input or {}
      open_subtask(term, {
        id = task_id,
        kind = 'bash',
        description = tool_input.description or tool_input.command,
        open = true,
      })
    end
  elseif event == 'SubagentStart' then
    open_subtask(term, { id = input.agent_id, kind = 'agent', description = input.agent_type, open = true })
  elseif event == 'SubagentStop' then
    local subtask = session(term.session_id).subtasks[input.agent_id]
    if subtask then
      close_subtask(term, subtask)
    end
    sweep_background(term, input.background_tasks)
  end
end

--- Serves `POST /hooks/<Event>` for every registered hook event.
--- @param server bodgery.http.Server
function M.register(server)
  for _, event in ipairs(require('bodgery.harness.claude.config').hook_events) do
    server:route({
      method = 'POST',
      path = '/hooks/' .. event,
      handler = function(req)
        local ok, input = pcall(vim.json.decode, req.body, { luanil = { object = true, array = true } })
        if not ok or type(input) ~= 'table' then
          return 400, { error = 'expected a JSON object' }
        end
        --- @type bodgery.Terminal
        local term = req.ctx
        M.on_hook(event, input, term)

        local callback = term.config.hooks[event]
        if not callback then
          return 200, vim.empty_dict()
        end
        local cok, result = pcall(callback, input, { session_id = term.session_id, bufnr = term.bufnr })
        if not cok then
          vim.notify(('bodgery: hooks.%s failed: %s'):format(event, result), vim.log.levels.ERROR)
          return 200, vim.empty_dict()
        end
        return 200, result == nil and vim.empty_dict() or result
      end,
    })
  end
end

return M
