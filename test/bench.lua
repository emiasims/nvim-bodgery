-- Times sessions() over 1000 generated sessions with 1 MB transcripts in 20 projects.
--
--   make bench
--
-- Fails when a timing exceeds its budget. The generated tree (about 1 GB) lives in a
-- temporary directory and is removed afterwards.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0])))
package.path = ('%s/lua/?.lua;%s/lua/?/init.lua;%s'):format(root, root, package.path)

local SESSIONS, PROJECTS, SIZE = 1000, 20, 1024 * 1024

-- milliseconds, about twice the first measured run (188 and 29 ms on an M-series Mac)
local budgets = { all = 400, project = 60 }

local tmp = vim.fn.tempname()
vim.env.CLAUDE_CONFIG_DIR = tmp .. '/claude'
local ccd = tmp .. '/ccd'
vim.fn.mkdir(ccd .. '/acct/org', 'p')

local filler = vim.json.encode({
  type = 'assistant',
  message = { role = 'assistant', content = { { type = 'text', text = ('x'):rep(2000) } } },
  cwd = '/bench',
}) .. '\n'
local body = filler:rep(math.floor(SIZE / #filler))

for p = 1, PROJECTS do
  local cwd = '/bench/project-' .. p
  local dir = ('%s/claude/projects/%s'):format(tmp, cwd:gsub('[^%w]', '-'))
  vim.fn.mkdir(dir, 'p')
  for s = 1, SESSIONS / PROJECTS do
    local id = ('p%d-s%d'):format(p, s)
    local f = assert(io.open(('%s/%s.jsonl'):format(dir, id), 'w'))
    f:write(
      vim.json.encode({ type = 'user', message = { role = 'user', content = 'prompt ' .. id }, cwd = cwd }),
      '\n'
    )
    f:write(body)
    f:write(vim.json.encode({ type = 'ai-title', aiTitle = 'title ' .. id, sessionId = id }), '\n')
    f:close()
    if s % 5 == 0 then
      vim.fn.writefile(
        { vim.json.encode({ cliSessionId = id, title = 'ccd ' .. id, isArchived = s % 10 == 0 }) },
        ('%s/acct/org/local_%s.json'):format(ccd, id)
      )
    end
  end
end

require('bodging').setup({ ccd_dir = ccd })
local sessions = require('bodging.harness.claude.sessions')

local function time(filter)
  local start = vim.uv.hrtime()
  local n = 0
  for _ in sessions.sessions(filter) do
    n = n + 1
  end
  return (vim.uv.hrtime() - start) / 1e6, n
end

-- one warm-up pass so the file cache doesn't decide the numbers
time()
local failed = false
for _, case in ipairs({ { 'all' }, { 'project', { cwd = '/bench/project-7' } } }) do
  local name, filter = case[1], case[2]
  local ms, n = time(filter)
  local ok = ms <= budgets[name]
  failed = failed or not ok
  print(
    ('%-8s %4d sessions  %7.1f ms  (budget %d ms)%s'):format(
      name,
      n,
      ms,
      budgets[name],
      ok and '' or '  OVER'
    )
  )
end

vim.fn.delete(tmp, 'rf')
os.exit(failed and 1 or 0)
