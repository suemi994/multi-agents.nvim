local api = vim.api
local terminal = require('claude-code.terminal')
local git = require('claude-code.git')

---@class MultiAgent
---@field name string
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
local has_split_api = vim.fn.has('nvim-0.10') == 1
local has_terminal_jobstart = vim.fn.has('nvim-0.11') == 1

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
    if value ~= 'float' and value ~= 'vertical' then
      error('OpenAgent: --mode expects float or vertical', 0)
    end
    mode, command = value, remaining
  end
  return mode, command ~= '' and command or vim.trim(config.command)
end

local agent_names = { codex = true, claude = true, pi = true, agy = true, dsh = true }

local function unique_name(command)
  local base = command:match('^%S+')
  for word in command:gmatch([[[^%s'";|&()<>]+]]) do
    local executable = word:match('[^/]+$')
    if executable and agent_names[executable] then
      base = executable
      break
    end
  end
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

local function find_agent(name)
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
  error('Unknown agent: ' .. name, 0)
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

local function open_window(agent)
  local window = config.window
  local win
  if agent.mode == 'float' then
    win = api.nvim_open_win(agent.buf, true, terminal.float_config(window.float))
    vim.wo[win].winhighlight = 'Normal:Normal'
  else
    local layout = window.vertical
    if has_split_api then
      win =
        api.nvim_open_win(agent.buf, true, { split = layout.side, win = -1, width = split_width() })
    else
      local side = layout.side == 'left' and 'topleft' or 'botright'
      vim.cmd(('%s vertical sbuffer %d'):format(side, agent.buf))
      win = api.nvim_get_current_win()
      api.nvim_win_set_width(win, split_width())
    end
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
  local name = unique_name(command)
  local cwd = config.git.use_git_root and git.get_git_root() or nil
  local buf = api.nvim_create_buf(false, true)
  local agent = { name = name, buf = buf, mode = mode, command = command, started_at = os.time() }
  vim.bo[buf].bufhidden = 'hide'

  local ok, win_or_err = pcall(function()
    local win = open_window(agent)
    local job = api.nvim_buf_call(buf, function()
      -- Extend the child process environment without changing shell quoting or Neovim's environment.
      local opts = {
        cwd = cwd,
        env = next(config.env) and config.env or nil,
        on_exit = vim.schedule_wrap(function()
          close(agent)
        end),
      }
      if has_terminal_jobstart then
        opts.term = true
        return vim.fn.jobstart(command, opts)
      end
      return vim.fn.termopen(command, opts)
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
    activate(agent, open_window(agent))
  end
end

function M.close(name)
  local agent = name and name ~= '' and find_agent(name) or selected
  if agent then
    close(agent)
  end
end

local function abbreviate(command, width)
  if vim.fn.strdisplaywidth(command) <= width then
    return command
  end
  local ellipsis = '…'
  local limit = width - vim.fn.strdisplaywidth(ellipsis)
  if limit < 0 then
    return '.'
  end
  local function prefix(length)
    return command:sub(1, vim.fn.byteidx(command, length))
  end
  local first, last = 0, math.min(limit, vim.fn.strchars(command, true))
  while first < last do
    local mid = math.ceil((first + last) / 2)
    if vim.fn.strdisplaywidth(prefix(mid)) <= limit then
      first = mid
    else
      last = mid - 1
    end
  end
  return prefix(first) .. ellipsis
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
    local row = 2 * index - 1
    lines[row] = ('%s %s [%s]  PID %s  %s'):format(
      is_selected and '*' or ' ',
      agent.name,
      agent.mode,
      agent.pid or '-',
      os.date('%Y-%m-%d %H:%M:%S', agent.started_at)
    )
    lines[row + 1] = abbreviate(vim.fn.strtrans(agent.command), win_config.width)
    if is_selected then
      cursor = row
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
    return math.ceil(api.nvim_win_get_cursor(win)[1] / 2)
  end
  local function move(delta)
    return function()
      local index = math.max(1, math.min(#entries, current_index() + delta))
      api.nvim_win_set_cursor(win, { 2 * index - 1, 0 })
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

local function set_toggle_key(mode, lhs)
  local rhs, desc = '<Cmd>ToggleAgent<CR>', 'Toggle terminal agent'
  local previous = toggle_keys[mode]
  local current = lhs and api.nvim_replace_termcodes(lhs, true, true, true) or nil
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
  api.nvim_create_user_command('ToggleAgent', function(cmd)
    M.toggle(cmd.args)
  end, { nargs = '?', complete = complete_names, desc = 'Toggle a terminal agent' })
  api.nvim_create_user_command('CloseAgent', function(cmd)
    M.close(cmd.args)
  end, { nargs = '?', complete = complete_names, desc = 'Close a terminal agent' })
  set_toggle_key('n', config.keymaps.toggle.normal)
  set_toggle_key('t', config.keymaps.toggle.terminal)
end

return M
