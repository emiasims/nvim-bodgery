local launch = require('bodgery.harness.claude.launch')

local M = {}

--- Bytes read from the start of a transcript while looking for `cwd` and the first prompt.
M.head_cap = 1024 * 1024

--- Bytes read from the end of a transcript for title records, which Claude re-appends
--- near the end as a session goes on.
M.tail_bytes = 64 * 1024

local CHUNK = 64 * 1024

local FILE_TOOLS =
  { Read = 'file_path', Edit = 'file_path', Write = 'file_path', NotebookEdit = 'notebook_path' }

--- @class bodgery.Session
--- @field id string
--- @field last_activity integer seconds since the epoch
--- @field cwd? string
--- @field title? string
--- @field archived? boolean
--- @field live? { pid: integer, status: string?, name: string? }
--- @field bufnr? integer the plugin terminal holding the session

--- @class bodgery.SessionFilter
--- @field cwd? string only sessions started in this directory
--- @field archived? boolean
--- @field fields? string[] fields to fill beyond `id` and `last_activity`, default all

--- @param line string
--- @return table?
local function decode(line)
  local ok, rec = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  return ok and type(rec) == 'table' and rec or nil
end

--- Complete lines from the first `cap` bytes of `path`.
--- @param path string
--- @param cap integer
--- @return fun(): string?
local function head_lines(path, cap)
  local f = io.open(path, 'rb')
  local buf, read, pos = '', 0, 1
  return function()
    while f do
      local nl = buf:find('\n', pos, true)
      if nl then
        local line = buf:sub(pos, nl - 1)
        pos = nl + 1
        return line
      end
      local chunk = read < cap and f:read(math.min(CHUNK, cap - read))
      if not chunk then
        f:close()
        f = nil
        return nil
      end
      read = read + #chunk
      buf, pos = buf:sub(pos) .. chunk, 1
    end
  end
end

--- Complete lines from the last `bytes` of `path`.
--- @param path string
--- @param bytes integer
--- @return string[]
local function tail_lines(path, bytes)
  local f = io.open(path, 'rb')
  if not f then
    return {}
  end
  local size = f:seek('end')
  f:seek('set', math.max(0, size - bytes))
  local text = f:read('*a') or ''
  f:close()
  local lines = vim.split(text, '\n', { plain = true })
  if size > bytes then
    table.remove(lines, 1)
  end
  return lines
end

--- The text of a user prompt, or nil for tool results, commands, and injected context.
--- @param rec table
--- @return string?
local function prompt_text(rec)
  if rec.type ~= 'user' or rec.isMeta or type(rec.message) ~= 'table' then
    return
  end
  local content = rec.message.content
  if type(content) == 'table' then
    for _, block in ipairs(content) do
      if block.type == 'text' then
        content = block.text
        break
      end
    end
  end
  if type(content) ~= 'string' or content:find('^%s*<') then
    return
  end
  local first = vim.trim(content):match('^[^\n]*')
  return first ~= '' and first or nil
end

--- `cwd` and the first prompt, read from the start of the transcript until both are found.
--- @param path string
--- @return string? cwd
--- @return string? prompt
local function read_head(path)
  local cwd, prompt
  for line in head_lines(path, M.head_cap) do
    local maybe_cwd = not cwd and line:find('"cwd":"', 1, true)
    local maybe_user = not prompt and line:find('"type":"user"', 1, true)
    if maybe_cwd or maybe_user then
      local rec = decode(line)
      if rec then
        cwd = cwd or (type(rec.cwd) == 'string' and rec.cwd or nil)
        prompt = prompt or prompt_text(rec)
      end
    end
    if cwd and prompt then
      break
    end
  end
  return cwd, prompt
end

--- The latest `custom-title`, `agent-name`, and `ai-title` near the end of the transcript.
--- @param path string
--- @return table<string, string>
local function read_titles(path)
  local out = {}
  local keys = { ['custom-title'] = 'customTitle', ['agent-name'] = 'agentName', ['ai-title'] = 'aiTitle' }
  for _, line in ipairs(tail_lines(path, M.tail_bytes)) do
    for kind, key in pairs(keys) do
      if line:find('"type":"' .. kind .. '"', 1, true) then
        local rec = decode(line)
        local value = rec and rec[key]
        if type(value) == 'string' and value ~= '' then
          out[kind] = value
        end
        break
      end
    end
  end
  return out
end

--- Bumped when the shape of a cache entry changes, which discards the cache on disk.
local CACHE_VERSION = 1

--- What was read from each transcript and ccd record, keyed by path and valid while the
--- file's stamp matches.
--- @class bodgery.claude.Cache
--- @field version integer
--- @field transcripts table<string, { stamp: string, head?: true, cwd?: string, prompt?: string, titles?: table<string, string> }>
--- @field ccd table<string, { stamp: string, id?: string, title?: string, archived?: boolean }>

--- @type bodgery.claude.Cache?
local cache
local dirty = false

--- @return string
local function cache_path()
  return vim.fs.joinpath(vim.fn.stdpath('cache'), 'bodgery', 'claude-sessions.mpack')
end

--- @return bodgery.claude.Cache
local function load_cache()
  if not cache then
    local f = io.open(cache_path(), 'rb')
    local ok, data = false, nil
    if f then
      ok, data = pcall(vim.mpack.decode, f:read('*a'))
      f:close()
    end
    cache = ok and type(data) == 'table' and data.version == CACHE_VERSION and data
      or { version = CACHE_VERSION, transcripts = {}, ccd = {} }
  end
  return cache
end

local function save_cache()
  if not dirty then
    return
  end
  dirty = false
  local path = cache_path()
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  -- another Neovim reading the cache mid-write sees the old file, never a partial one
  local tmp = ('%s.%d'):format(path, vim.fn.getpid())
  local f = io.open(tmp, 'wb')
  if f then
    f:write(vim.mpack.encode(cache))
    f:close()
    vim.uv.fs_rename(tmp, path)
  end
end

--- Saves the cache once the caller yields, since callers may stop iterating early.
local function touch_cache()
  if not dirty then
    dirty = true
    vim.schedule(save_cache)
  end
end

--- @param stat uv.fs_stat.result
--- @return string
local function stamp(stat)
  return ('%d.%d:%d'):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
end

--- Drops entries under `root` missing from `seen`.
--- @param entries table<string, table>
--- @param root string
--- @param seen table<string, true>
local function prune(entries, root, seen)
  for path in pairs(entries) do
    if not seen[path] and vim.startswith(path, root .. '/') then
      entries[path] = nil
      touch_cache()
    end
  end
end

--- The cache entry for `file`, reading the transcript's head or tail when requested and
--- not yet cached.
--- @param file { path: string, stamp: string }
--- @param head boolean?
--- @param tail boolean?
local function transcript_meta(file, head, tail)
  local entries = load_cache().transcripts
  local e = entries[file.path]
  if not e or e.stamp ~= file.stamp then
    e = { stamp = file.stamp }
    entries[file.path] = e
  end
  if head and not e.head then
    e.head, e.cwd, e.prompt = true, read_head(file.path)
    touch_cache()
  end
  if tail and not e.titles then
    e.titles = read_titles(file.path)
    touch_cache()
  end
  return e
end

--- Claude's project directory name for `cwd`.
--- @param cwd string
--- @return string
function M.slug(cwd)
  return (cwd:gsub('[^%w]', '-'))
end

--- @return string
local function projects_dir()
  return vim.fs.joinpath(launch.config_dir(), 'projects')
end

--- Transcripts with their modification time, newest first.
--- @param cwd? string
--- @return { id: string, path: string, mtime: integer, stamp: string }[]
local function transcripts(cwd)
  local root = projects_dir()
  local dirs = {}
  if cwd then
    dirs[1] = vim.fs.joinpath(root, M.slug(cwd))
  else
    for name, kind in vim.fs.dir(root) do
      if kind == 'directory' then
        dirs[#dirs + 1] = vim.fs.joinpath(root, name)
      end
    end
  end
  local out = {}
  for _, dir in ipairs(dirs) do
    for name, kind in vim.fs.dir(dir) do
      local id = kind == 'file' and name:match('^(.+)%.jsonl$')
      local stat = id and vim.uv.fs_stat(vim.fs.joinpath(dir, name))
      if stat then
        local path = vim.fs.joinpath(dir, name)
        out[#out + 1] = { id = id, path = path, mtime = stat.mtime.sec, stamp = stamp(stat) }
      end
    end
  end
  if not cwd then
    local seen = {}
    for _, file in ipairs(out) do
      seen[file.path] = true
    end
    prune(load_cache().transcripts, root, seen)
  end
  table.sort(out, function(a, b)
    return a.mtime > b.mtime
  end)
  return out
end

--- ccd's session records keyed by Claude's session id.
--- @param root string
--- @return table<string, { title: string?, archived: boolean? }>
local function ccd_index(root)
  local entries = load_cache().ccd
  local out, seen = {}, {}
  for name, kind in vim.fs.dir(root, { depth = 3 }) do
    local path = vim.fs.joinpath(root, name)
    local stat = kind == 'file' and vim.fs.basename(name):match('^local_.*%.json$') and vim.uv.fs_stat(path)
    if stat then
      seen[path] = true
      local e = entries[path]
      if not e or e.stamp ~= stamp(stat) then
        local f = io.open(path, 'rb')
        local rec = f and decode(f:read('*a')) or {}
        if f then
          f:close()
        end
        e = {
          stamp = stamp(stat),
          id = type(rec.cliSessionId) == 'string' and rec.cliSessionId or nil,
          title = type(rec.title) == 'string' and rec.title or nil,
          archived = rec.isArchived == true,
        }
        entries[path] = e
        touch_cache()
      end
      if e.id then
        out[e.id] = e
      end
    end
  end
  prune(entries, root, seen)
  return out
end

--- @param pid integer
--- @return boolean
local function alive(pid)
  return vim.uv.kill(pid, 0) == 0
end

--- Sessions with a running Claude process, keyed by session id.
--- @return table<string, { pid: integer, status: string?, name: string? }>
function M.live()
  local out = {}
  local dir = vim.fs.joinpath(launch.config_dir(), 'sessions')
  for name, kind in vim.fs.dir(dir) do
    if kind == 'file' and name:match('^%d+%.json$') then
      local f = io.open(vim.fs.joinpath(dir, name), 'rb')
      local rec = f and decode(f:read('*a'))
      if f then
        f:close()
      end
      if rec and type(rec.sessionId) == 'string' and type(rec.pid) == 'number' and alive(rec.pid) then
        -- derived names are cwd-plus-number placeholders that change on every resume
        local chosen = rec.nameSource ~= 'derived' and rec.name or nil
        out[rec.sessionId] = { pid = rec.pid, status = rec.status, name = chosen }
      end
    end
  end
  return out
end

--- Sessions newest first, reading only the files the requested fields need.
--- @param filter? bodgery.SessionFilter
--- @param config bodgery.Config
--- @return fun(): bodgery.Session?
function M.sessions(filter, config)
  filter = filter or {}
  local want = {}
  for _, field in ipairs(filter.fields or { 'cwd', 'title', 'archived', 'live', 'bufnr' }) do
    want[field] = true
  end
  local cwd = filter.cwd and vim.fs.normalize(vim.fs.abspath(filter.cwd))
  local files = transcripts(cwd)
  local ccd = (want.title or want.archived or filter.archived ~= nil) and ccd_index(config.ccd_dir) or {}
  local live = (want.live or want.title) and M.live() or {}
  local terms = {}
  for bufnr, term in pairs(require('bodgery.terminal').terminals) do
    if term.session_id then
      terms[term.session_id] = bufnr
    end
  end

  local i = 0
  return function()
    while true do
      i = i + 1
      local file = files[i]
      if not file then
        save_cache()
        return nil
      end
      local index = ccd[file.id] or {}
      local archived = index.archived == true
      local s = { id = file.id, last_activity = file.mtime }
      local head = (want.cwd or want.title or cwd) and transcript_meta(file, true) or {}
      local head_cwd, prompt = head.cwd, head.prompt
      -- different directories can share a slug
      if (filter.archived == nil or filter.archived == archived) and (not cwd or head_cwd == cwd) then
        if want.cwd then
          s.cwd = head_cwd
        end
        if want.archived then
          s.archived = archived
        end
        if want.live then
          s.live = live[file.id]
        end
        if want.bufnr then
          s.bufnr = terms[file.id]
        end
        if want.title then
          local titles = type(index.title) == 'string' and {} or transcript_meta(file, false, true).titles
          s.title = type(index.title) == 'string' and index.title
            or titles['custom-title']
            or titles['agent-name']
            or (live[file.id] or {}).name
            or titles['ai-title']
            or prompt
        end
        return s
      end
    end
  end
end

--- @param id string
--- @return string? path
local function find_transcript(id)
  return vim.fn.glob(vim.fs.joinpath(projects_dir(), '*', id .. '.jsonl'), true, true)[1]
end

--- Every parseable record of a transcript whose line contains one of `needles`.
--- @param path string
--- @param needles string[]
--- @return fun(): table?
local function records(path, needles)
  local lines = head_lines(path, math.huge)
  return function()
    for line in lines do
      for _, needle in ipairs(needles) do
        if line:find(needle, 1, true) then
          local rec = decode(line)
          if rec then
            return rec
          end
          break
        end
      end
    end
  end
end

--- @param rec table
--- @return table[]
local function blocks(rec)
  local content = type(rec.message) == 'table' and rec.message.content
  return type(content) == 'table' and content or {}
end

--- Files Claude read or edited, from tool calls in the transcript and its subagents'
--- transcripts and from file-history records, in first-seen order.
--- @param id string
--- @return string[]
function M.touched(id)
  local out, seen = {}, {}
  local function add(path)
    if type(path) == 'string' and not seen[path] then
      seen[path] = true
      out[#out + 1] = path
    end
  end
  local main = find_transcript(id)
  if not main then
    return out
  end
  local paths = { main }
  vim.list_extend(paths, vim.fn.glob(main:gsub('%.jsonl$', '') .. '/subagents/*.jsonl', true, true))
  for _, path in ipairs(paths) do
    for rec in records(path, { '"tool_use"', '"file-history-' }) do
      for _, block in ipairs(blocks(rec)) do
        local key = block.type == 'tool_use' and FILE_TOOLS[block.name]
        if key and type(block.input) == 'table' then
          add(block.input[key])
        end
      end
      local backups = type(rec.snapshot) == 'table' and rec.snapshot.trackedFileBackups
      local tracked = {}
      if type(backups) == 'table' then
        for file, backup in pairs(backups) do
          tracked[#tracked + 1] = { file, backup }
        end
        table.sort(tracked, function(a, b)
          return a[1] < b[1]
        end)
      elseif type(rec.trackingPath) == 'string' then
        tracked[1] = { rec.trackingPath, rec.backup }
      end
      for _, entry in ipairs(tracked) do
        local file, backup = entry[1], entry[2]
        local parent = type(backup) == 'table' and backup.realParentDir or rec.cwd
        add(file:sub(1, 1) == '/' and file or parent and vim.fs.joinpath(parent, file) or file)
      end
    end
  end
  return out
end

--- Subagents and background Bash tasks from the transcript. A subtask is open while the
--- session is live and Claude hasn't reported it finished.
--- @param id string
--- @return bodgery.Subtask[]
function M.subtasks(id)
  local main = find_transcript(id)
  if not main then
    return {}
  end
  local by_id, order = {}, {}
  local function add(subtask)
    if not by_id[subtask.id] then
      order[#order + 1] = subtask.id
    end
    by_id[subtask.id] = subtask
  end

  local results, notified, bash_inputs = {}, {}, {}
  for rec in records(main, { '"tool_use"', '"tool_result"', '<task-notification>' }) do
    for _, block in ipairs(blocks(rec)) do
      if block.type == 'tool_use' and block.name == 'Bash' and type(block.input) == 'table' then
        bash_inputs[block.id] = block.input
      elseif block.type == 'tool_result' then
        results[block.tool_use_id] = true
      end
    end
    local task = type(rec.toolUseResult) == 'table' and rec.toolUseResult.backgroundTaskId
    local use_id = (blocks(rec)[1] or {}).tool_use_id
    if type(task) == 'string' then
      local input = bash_inputs[use_id] or {}
      add({ id = task, kind = 'bash', description = input.description or input.command })
    end
    local text = rec.type == 'user' and type(rec.message) == 'table' and rec.message.content
    if type(text) == 'string' then
      for note in text:gmatch('<task%-notification>(.-)</task%-notification>') do
        local task_id = note:match('<task%-id>([^<]+)</task%-id>')
        if task_id then
          notified[task_id] = note:match('<output%-file>([^<]+)</output%-file>') or true
        end
      end
    end
  end

  local dir = main:gsub('%.jsonl$', '') .. '/subagents'
  local agents = {}
  for name in vim.fs.dir(dir) do
    local agent = name:match('^agent%-(.+)%.meta%.json$')
    local f = agent and io.open(vim.fs.joinpath(dir, name), 'rb')
    if f then
      local meta = decode(f:read('*a')) or {}
      f:close()
      agents[#agents + 1] = { id = agent, meta = meta }
    end
  end
  table.sort(agents, function(a, b)
    return a.id < b.id
  end)
  for _, a in ipairs(agents) do
    add({
      id = a.id,
      kind = 'agent',
      description = a.meta.description or a.meta.agentType,
      path = vim.fs.joinpath(dir, ('agent-%s.jsonl'):format(a.id)),
      -- a foreground agent's tool result is its final answer
      done = a.meta.requestShape ~= 'background' and results[a.meta.toolUseId],
    })
  end

  local live = M.live()[id] ~= nil
  local out = {}
  for _, key in ipairs(order) do
    local s = by_id[key]
    local note = notified[s.id]
    out[#out + 1] = {
      id = s.id,
      kind = s.kind,
      description = s.description,
      open = live and not note and not s.done,
      path = s.path or (type(note) == 'string' and note or nil),
    }
  end
  return out
end

return M
