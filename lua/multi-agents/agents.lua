local api = vim.api
local terminal = require('claude-code.terminal')
local git = require('claude-code.git')

---@class MultiAgent
---@field name string
---@field agent_name string
---@field buf integer
---@field mode 'float'|'vertical'
---@field command string
---@field started_at integer
---@field pid? integer

local M = {}
local config ---@type ClaudeCodeConfig
local agents = {} ---@type MultiAgent[]
local selected ---@type MultiAgent?
local shown ---@type MultiAgent?
local picker ---@type integer?
local toggle_keys = {} ---@type table<string, string>
local modes = { 'float', 'vertical' }

local function parse_open_args(args)
  local mode = config.window.mode
  local command = vim.trim(args or '')
  while command:sub(1, 2) == '--' do
    local flag, rest = command:match('^(%S+)%s*(.*)$')
    if flag == '--' then
      command = rest
      break
    end
    if flag ~= '--mode' then
      error('OpenAgent: unknown option ' .. flag, 0)
    end
    local value, remaining = rest:match('^(%S+)%s*(.*)$')
    if not vim.tbl_contains(modes, value) then
      error('OpenAgent: --mode expects float or vertical', 0)
    end
    mode, command = value, remaining
  end
  return mode, command ~= '' and command or vim.trim(config.command)
end

local agent_names = { codex = true, claude = true, pi = true, agy = true, dsh = true }

local function get_agent_name(command)
  for word in command:gmatch([[[^%s'";|&()<>]+]]) do
    local executable = word:match('[^/]+$')
    if executable and agent_names[executable] then
      return executable
    end
  end
  return command:match('^%S+')
end

local function unique_name(base)
  local used_names = {}
  for _, agent in ipairs(agents) do
    used_names[agent.name] = true
  end
  local buffer_names = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    buffer_names[api.nvim_buf_get_name(buf)] = true
  end

  local name, suffix = base, 2
  while used_names[name] or buffer_names[vim.fn.fnamemodify(name, ':p')] do
    name = base .. '-' .. suffix
    suffix = suffix + 1
  end
  return name
end

local function remove(agent)
  for index, entry in ipairs(agents) do
    if entry == agent then
      table.remove(agents, index)
      if selected == agent then
        selected = agents[index] or agents[1]
      end
      if shown == agent then
        shown = nil
      end
      return true
    end
  end
  return false
end

local function close(agent)
  if remove(agent) and api.nvim_buf_is_valid(agent.buf) then
    api.nvim_buf_delete(agent.buf, { force = true })
  end
end

local function get_agent(name)
  for _, agent in ipairs(agents) do
    if agent.name == name then
      return agent
    end
  end
  for _, agent in ipairs(agents) do
    if tostring(agent.buf) == name then
      return agent
    end
  end
end

local function find_agent(name)
  return get_agent(name) or error('Unknown agent: ' .. name, 0)
end

local function hide(agent)
  for _, win in ipairs(vim.fn.win_findbuf(agent.buf)) do
    if not pcall(api.nvim_win_hide, win) then
      -- A split can become the last window in its tab if others were closed.
      api.nvim_win_set_buf(win, api.nvim_create_buf(true, false))
    end
  end
end

local function split_width()
  return math.max(1, math.floor(vim.o.columns * config.window.vertical.split_ratio))
end

local function open_window(agent, mode, enter)
  local window = config.window
  local win
  if mode == 'float' then
    win = api.nvim_open_win(agent.buf, enter, terminal.float_config(window.float))
    vim.wo[win].winhighlight = 'Normal:Normal'
  else
    local layout = window.vertical
    win =
      api.nvim_open_win(agent.buf, enter, { split = layout.side, win = -1, width = split_width() })
  end
  if window.hide_numbers then
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
  end
  if window.hide_signcolumn then
    vim.wo[win].signcolumn = 'no'
  end
  return win
end

local function activate(agent, win)
  if shown and shown ~= agent then
    hide(shown)
    if agent.mode == 'vertical' then
      -- 'equalalways' may resize the new split when the previous one closes.
      api.nvim_win_set_width(win, split_width())
    end
  end
  selected, shown = agent, agent
  if config.window.enter_insert and not config.window.start_in_normal_mode then
    vim.cmd.startinsert()
  end
end

function M.open(args, forced_mode)
  local mode, command = parse_open_args(args)
  mode = forced_mode or mode
  local agent_name = get_agent_name(command)
  local name = unique_name(agent_name)
  local cwd = config.git.use_git_root and git.get_git_root() or nil
  local buf = api.nvim_create_buf(false, true)
  local agent = {
    name = name,
    agent_name = agent_name,
    buf = buf,
    mode = mode,
    command = command,
    started_at = os.time(),
  }
  vim.bo[buf].bufhidden = 'hide'

  local ok, win_or_err = pcall(function()
    local win = open_window(agent, agent.mode, true)
    local job = api.nvim_buf_call(buf, function()
      -- Extend the child process environment without changing shell quoting or Neovim's environment.
      return vim.fn.jobstart(command, {
        term = true,
        cwd = cwd,
        env = next(config.env) and config.env or nil,
        on_exit = vim.schedule_wrap(function()
          close(agent)
        end),
      })
    end)
    if job <= 0 then
      error('Unable to start terminal job', 0)
    end
    local has_pid, pid = pcall(vim.fn.jobpid, job)
    if has_pid and pid > 0 then
      agent.pid = pid
    end
    api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buflisted = false
    api.nvim_create_autocmd('BufUnload', {
      buffer = buf,
      once = true,
      callback = function()
        remove(agent)
      end,
    })
    return win
  end)
  if not ok then
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
    error('OpenAgent: ' .. tostring(win_or_err), 0)
  end

  table.insert(agents, agent)
  activate(agent, win_or_err)
  return buf
end

function M.toggle(name)
  local agent = name and name ~= '' and find_agent(name) or selected
  if not agent then
    return M.open()
  end
  if #vim.fn.win_findbuf(agent.buf) > 0 then
    hide(agent)
    selected = agent
    if shown == agent then
      shown = nil
    end
  else
    activate(agent, open_window(agent, agent.mode, true))
  end
end

local function reshape_window(agent, win, mode)
  local tab = api.nvim_win_get_tabpage(win)
  local anchor = win
  for _, other in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if other ~= win and api.nvim_win_get_config(other).relative == '' then
      anchor = other
      break
    end
  end

  local focused = win == api.nvim_get_current_win()
  local replacement = api.nvim_win_call(anchor, function()
    local new_win = open_window(agent, mode, false)
    if mode == 'float' and anchor == win then
      -- Keep a normal window when the agent is the only split in its tab.
      api.nvim_win_set_buf(win, api.nvim_create_buf(true, false))
    else
      api.nvim_win_hide(win)
    end
    return new_win
  end)
  if focused then
    api.nvim_set_current_win(replacement)
  end
end

function M.reshape(name, mode)
  if mode ~= nil and not vim.tbl_contains(modes, mode) then
    error('ReshapeAgent: mode must be float or vertical', 0)
  end
  local agent = name and name ~= '' and find_agent(name) or selected
  if not agent then
    return
  end
  if not mode then
    local index = vim.fn.index(modes, agent.mode)
    mode = modes[(index + 1) % #modes + 1]
  end
  if mode == agent.mode then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(agent.buf)) do
    reshape_window(agent, win, mode)
  end
  agent.mode = mode
end

function M.close(name)
  local agent = name and name ~= '' and find_agent(name) or selected
  if agent then
    close(agent)
  end
end

function M.select(target)
  target = tostring(target)
  local by_name, by_pid
  for _, agent in ipairs(agents) do
    local buffer_name = api.nvim_buf_get_name(agent.buf)
    if target == buffer_name or target == vim.fn.fnamemodify(buffer_name, ':t') then
      selected = agent
      return agent.buf
    end
    if not by_name and target == agent.agent_name then
      by_name = agent
    end
    if not by_pid and agent.pid and target == tostring(agent.pid) then
      by_pid = agent
    end
  end

  local agent = by_name or by_pid
  if not agent then
    error('SelectAgent: unknown agent: ' .. target, 0)
  end
  selected = agent
  return agent.buf
end

function M.list()
  if picker and api.nvim_win_is_valid(picker) then
    api.nvim_win_close(picker, true)
    return
  end
  if #agents == 0 then
    vim.notify('No active agents', vim.log.levels.INFO)
    return
  end

  local layout = vim.tbl_extend('force', config.window.float, { width = '70%', height = '50%' })
  local win_config = terminal.float_config(layout)
  local entries = vim.list_extend({}, agents)
  local lines, cursor = {}, 1
  for index, agent in ipairs(entries) do
    local is_selected = agent == selected
    lines[index] = ('%s [%s] %s  [%s]  PID %s  %s'):format(
      is_selected and '*' or ' ',
      vim.fn.strtrans(agent.name),
      vim.fn.strtrans(agent.command),
      agent.mode,
      agent.pid or '-',
      os.date('%Y-%m-%d %H:%M:%S', agent.started_at)
    )
    if is_selected then
      cursor = index
    end
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.cmd.stopinsert()
  local win = api.nvim_open_win(buf, true, win_config)
  picker = win
  vim.wo[win].winhighlight = 'Normal:Normal,NormalFloat:Normal'
  vim.wo[win].winblend = 0
  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = 'line'
  vim.wo[win].wrap = false
  api.nvim_win_set_cursor(win, { cursor, 0 })

  local function dismiss()
    api.nvim_win_close(win, true)
  end
  local function current_index()
    return api.nvim_win_get_cursor(win)[1]
  end
  local function move(delta)
    return function()
      local index = math.max(1, math.min(#entries, current_index() + delta))
      api.nvim_win_set_cursor(win, { index, 0 })
    end
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', '<Up>', move(-1), opts)
  vim.keymap.set('n', '<Down>', move(1), opts)
  vim.keymap.set('n', '<Esc>', dismiss, opts)
  vim.keymap.set('n', 'q', dismiss, opts)
  vim.keymap.set('n', '<CR>', function()
    local agent = entries[current_index()]
    if vim.tbl_contains(agents, agent) then
      selected = agent
    end
    dismiss()
  end, opts)
end

local function complete_names(lead)
  local matches = {}
  for _, agent in ipairs(agents) do
    if vim.startswith(agent.name, lead) then
      table.insert(matches, agent.name)
    end
  end
  return matches
end

local function complete_select(lead)
  local matches, seen = {}, {}
  local function add(value)
    if not seen[value] and vim.startswith(value, lead) then
      seen[value] = true
      table.insert(matches, value)
    end
  end
  for _, agent in ipairs(agents) do
    local buffer_name = api.nvim_buf_get_name(agent.buf)
    add(vim.fn.fnamemodify(buffer_name, ':t'))
    add(agent.agent_name)
    if agent.pid then
      add(tostring(agent.pid))
    end
  end
  return matches
end

local function complete_reshape(lead, cmdline, cursorpos)
  local ok, cmd = pcall(api.nvim_parse_cmd, cmdline:sub(1, cursorpos - #lead), {})
  local nargs = ok and #cmd.args or 0
  local name = ok and cmd.args[1] or nil
  if nargs >= 2 or (nargs == 1 and vim.tbl_contains(modes, name) and not get_agent(name)) then
    return {}
  end
  local matches = nargs == 0 and complete_names(lead) or {}
  for _, mode in ipairs(modes) do
    if vim.startswith(mode, lead) and not vim.tbl_contains(matches, mode) then
      table.insert(matches, mode)
    end
  end
  return matches
end

local function set_toggle_key(mode, lhs)
  local rhs, desc = '<Cmd>ToggleAgent<CR>', 'Toggle terminal agent'
  local previous = toggle_keys[mode]
  local current = lhs and vim.keycode(lhs) or nil
  if previous and previous ~= current then
    for _, mapping in ipairs(api.nvim_get_keymap(mode)) do
      if mapping.lhsraw == previous and mapping.rhs == rhs and mapping.desc == desc then
        vim.keymap.del(mode, mapping.lhs)
        break
      end
    end
  end

  if lhs then
    vim.keymap.set(mode, lhs, rhs, { silent = true, desc = desc })
  end
  toggle_keys[mode] = current
end

function M.setup(opts)
  config = opts
  api.nvim_create_user_command('OpenAgent', function(cmd)
    M.open(cmd.args)
  end, { nargs = '*', desc = 'Open a new terminal agent' })
  api.nvim_create_user_command('OpenFloat', function(cmd)
    M.open(cmd.args, 'float')
  end, { nargs = '*', desc = 'Open a new terminal agent in a floating window' })
  api.nvim_create_user_command('OpenVertical', function(cmd)
    M.open(cmd.args, 'vertical')
  end, { nargs = '*', desc = 'Open a new terminal agent in a vertical split' })
  api.nvim_create_user_command('ListAgent', M.list, { desc = 'Select the default terminal agent' })
  api.nvim_create_user_command('SelectAgent', function(cmd)
    M.select(cmd.args)
  end, { nargs = 1, complete = complete_select, desc = 'Set the default terminal agent' })
  api.nvim_create_user_command('ToggleAgent', function(cmd)
    M.toggle(cmd.args)
  end, { nargs = '?', complete = complete_names, desc = 'Toggle a terminal agent' })
  api.nvim_create_user_command('ReshapeAgent', function(cmd)
    if #cmd.fargs > 2 then
      error('ReshapeAgent: expected [BufferName] [mode]', 0)
    end
    local name, mode = unpack(cmd.fargs)
    if not mode and vim.tbl_contains(modes, name) and not get_agent(name) then
      name, mode = nil, name
    end
    M.reshape(name, mode)
  end, { nargs = '*', complete = complete_reshape, desc = 'Change an agent window mode' })
  api.nvim_create_user_command('CloseAgent', function(cmd)
    M.close(cmd.args)
  end, { nargs = '?', complete = complete_names, desc = 'Close a terminal agent' })
  set_toggle_key('n', config.keymaps.toggle.normal)
  set_toggle_key('t', config.keymaps.toggle.terminal)
end

return M
