-- Records one real Claude hook payload per event into test/fixtures/hooks/.
--
--   nvim --clean -l test/capture-hooks.lua
--
-- Runs real Claude three times (costs a few model calls):
--   1. `claude -p` in a temporary directory, reading, editing, writing, editing a notebook,
--      starting a subagent, and running a background Bash command
--   2. `claude -p --resume` on that session, for SessionStart with source `resume`
--   3. an interactive session in this repository (it must be trusted), asking for a Bash
--      command so the permission prompt fires Notification, then `/clear` and `/exit`
--
-- Files are named <Event>.json, <Event>-<tool>.json for tool events, and
-- SessionStart-<source>.json. The home directory becomes /home/test and the user name test.
local uv = vim.uv

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0])))
local out_dir = root .. '/test/fixtures/hooks'
local model = os.getenv('CAPTURE_MODEL') or 'sonnet'
vim.fn.mkdir(out_dir, 'p')

local home = assert(os.getenv('HOME'))
local user = assert(os.getenv('USER'))
local saved = {}
local log = {}

local function save(name, body)
  if saved[name] then
    return
  end
  saved[name] = true
  local data = vim.json.decode(body)
  local text = vim.json.encode(data):gsub(vim.pesc(home), '/home/test'):gsub(vim.pesc(user), 'test')
  local f = assert(io.open(('%s/%s.json'):format(out_dir, name), 'w'))
  f:write(text, '\n')
  f:close()
  print('saved ' .. name)
end

local function on_hook(event, body)
  local ok, data = pcall(vim.json.decode, body)
  if not ok then
    return
  end
  log[#log + 1] = data
  if event == 'SessionStart' then
    save('SessionStart-' .. data.source, body)
  elseif event == 'PreToolUse' or event == 'PostToolUse' then
    local name = event .. '-' .. data.tool_name
    if data.tool_name == 'Bash' and not (data.tool_input or {}).run_in_background then
      name = name .. '-foreground'
    end
    save(name, body)
  else
    save(event, body)
  end
end

-- logging server: answers every request with {}
local srv = assert(uv.new_tcp())
assert(srv:bind('127.0.0.1', 0))
local port = srv:getsockname().port
srv:listen(16, function()
  local c = assert(uv.new_tcp())
  srv:accept(c)
  local buf = ''
  c:read_start(function(err, data)
    if err or not data then
      return c:close()
    end
    buf = buf .. data
    while true do
      local he = buf:find('\r\n\r\n', 1, true)
      if not he then
        return
      end
      local head = buf:sub(1, he)
      local len = tonumber(head:lower():match('content%-length:%s*(%d+)') or '0')
      if #buf < he + 3 + len then
        return
      end
      local body = buf:sub(he + 4, he + 3 + len)
      buf = buf:sub(he + 4 + len)
      local event = head:match('^POST /hooks/(%w+)')
      if event then
        vim.schedule(function()
          on_hook(event, body)
        end)
      end
      c:write('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}')
    end
  end)
end)

local events = {
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
local hooks = {}
for _, event in ipairs(events) do
  local hook
  if event == 'SessionStart' then
    hook = {
      type = 'command',
      command = ("curl -sS --noproxy '*' -X POST -H 'Content-Type: application/json' --data-binary @- 'http://127.0.0.1:%d/hooks/SessionStart'"):format(
        port
      ),
    }
  else
    hook = { type = 'http', url = ('http://127.0.0.1:%d/hooks/%s'):format(port, event) }
  end
  hooks[event] = { { hooks = { hook } } }
end
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
local settings = tmp .. '/settings.json'
vim.fn.writefile({ vim.json.encode({ hooks = hooks }) }, settings)

local function wait_for(cond, ms, what)
  if not vim.wait(ms, cond, 100) then
    print('timed out waiting for ' .. what)
    return false
  end
  return true
end

local function session_id()
  for _, data in ipairs(log) do
    if data.session_id then
      return data.session_id
    end
  end
end

-- 1. headless run with tools and a subagent
local work = tmp .. '/work'
vim.fn.mkdir(work, 'p')
vim.fn.writefile({ 'hello world' }, work .. '/a.txt')
vim.fn.writefile({
  vim.json.encode({
    cells = {
      {
        cell_type = 'code',
        metadata = vim.empty_dict(),
        source = { 'print(1)' },
        outputs = {},
        execution_count = vim.NIL,
      },
    },
    metadata = vim.empty_dict(),
    nbformat = 4,
    nbformat_minor = 5,
  }),
}, work .. '/n.ipynb')

local prompt = table.concat({
  'Do these steps in order, one tool call each:',
  '1. Read a.txt.',
  "2. Use Edit to change 'hello' to 'goodbye' in a.txt.",
  "3. Use Write to create b.txt containing 'new'.",
  '4. Use NotebookEdit to replace the source of the first cell of n.ipynb with print(2).',
  '5. Start a subagent that reads b.txt and reports its contents.',
  '6. Run `sleep 2` with the Bash tool with run_in_background set to true.',
  '7. Run `echo hi` with the Bash tool in the foreground.',
  'Then reply with the word done.',
}, '\n')
print('running claude -p')
local res = vim
  .system({
    'claude',
    '-p',
    prompt,
    '--model',
    model,
    '--permission-mode',
    'acceptEdits',
    '--allowedTools',
    'Read,Edit,Write,NotebookEdit,Bash,Task,Agent',
    '--settings',
    settings,
  }, { cwd = work, text = true })
  :wait(300000)
print(res.stdout, res.stderr)
wait_for(function()
  return saved.SessionEnd
end, 10000, 'SessionEnd')

-- 2. resume
local id = session_id()
if id then
  print('running claude -p --resume ' .. id)
  vim
    .system(
      { 'claude', '-p', 'Reply ok.', '--resume', id, '--model', model, '--settings', settings },
      { cwd = work }
    )
    :wait(120000)
  wait_for(function()
    return saved['SessionStart-resume']
  end, 10000, 'SessionStart-resume')
end

-- 3. interactive: permission prompt, /clear, /exit
print('running interactive claude')
local job = vim.fn.jobstart({ 'claude', '--model', 'haiku', '--settings', settings }, {
  pty = true,
  cwd = root,
  width = 120,
  height = 40,
  on_stdout = function() end,
})
local function type_line(text)
  vim.fn.chansend(job, text)
  vim.wait(500)
  vim.fn.chansend(job, '\r')
end
wait_for(function()
  return saved['SessionStart-startup']
    and #vim.tbl_filter(function(d)
        return d.hook_event_name == 'SessionStart' and d.source == 'startup'
      end, log)
      >= 2
end, 30000, 'interactive SessionStart')
vim.wait(2000)
type_line('Run this exact shell command with the Bash tool: touch /tmp/claude-capture-hooks-x')
wait_for(function()
  return saved.Notification
end, 90000, 'Notification')
vim.fn.chansend(job, '\27')
vim.wait(3000)
type_line('/clear')
wait_for(function()
  return saved['SessionStart-clear']
end, 30000, 'SessionStart-clear')
vim.wait(2000)
type_line('/exit')
vim.fn.jobwait({ job }, 15000)
vim.fn.jobstop(job)

srv:close()
vim.fn.delete(tmp, 'rf')
local names = vim.tbl_keys(saved)
table.sort(names)
print('captured: ' .. table.concat(names, ', '))
