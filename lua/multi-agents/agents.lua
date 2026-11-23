local api = vim.api
local terminal = require('claude-code.terminal')
local git = require('claude-code.git')

---@class MultiAgent
---@field name string
---@field buf integer
---@field mode 'float'|'vertical'

local M = {}
local config ---@type ClaudeCodeConfig
local agents = {} ---@type MultiAgent[]
local selected ---@type MultiAgent?
local shown ---@type MultiAgent?
local picker ---@type integer?

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

local function unique_name(command)
  local base = command:match('^%S+')
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
    win =
      api.nvim_open_win(agent.buf, true, { split = layout.side, win = -1, width = split_width() })
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

function M.open(args)
  local mode, command = parse_open_args(args)
  local name = unique_name(command)
  local cwd = config.git.use_git_root and git.get_git_root() or nil
  local buf = api.nvim_create_buf(false, true)
  local agent = { name = name, buf = buf, mode = mode }
  vim.bo[buf].bufhidden = 'hide'

  local ok, win_or_err = pcall(function()
    local win = open_window(agent)
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

function M.list()
  if picker and api.nvim_win_is_valid(picker) then
    api.nvim_win_close(picker, true)
    return
  end
  if #agents == 0 then
    vim.notify('No active agents', vim.log.levels.INFO)
    return
  end

  local entries = vim.list_extend({}, agents)
  local lines, width, cursor = {}, 16, 1
  for index, agent in ipairs(entries) do
    lines[index] = agent.name .. '  [' .. agent.mode .. ']'
    width = math.max(width, vim.fn.strdisplaywidth(lines[index]))
    if agent == selected then
      cursor = index
    end
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.cmd.stopinsert()
  local win = api.nvim_open_win(
    buf,
    true,
    terminal.float_config({
      width = math.min(width, math.max(1, vim.o.columns - 2)),
      height = math.min(#lines, math.max(1, vim.o.lines - vim.o.cmdheight - 3)),
      row = 'center',
      col = 'center',
    })
  )
  picker = win
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  api.nvim_win_set_cursor(win, { cursor, 0 })

  local function dismiss()
    api.nvim_win_close(win, true)
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', '<Up>', 'k', opts)
  vim.keymap.set('n', '<Down>', 'j', opts)
  vim.keymap.set('n', '<Esc>', dismiss, opts)
  vim.keymap.set('n', 'q', dismiss, opts)
  vim.keymap.set('n', '<CR>', function()
    local agent = entries[api.nvim_win_get_cursor(win)[1]]
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

function M.setup(opts)
  config = opts
  api.nvim_create_user_command('OpenAgent', function(cmd)
    M.open(cmd.args)
  end, { nargs = '*', desc = 'Open a new terminal agent' })
  api.nvim_create_user_command('ListAgent', M.list, { desc = 'Select the default terminal agent' })
  api.nvim_create_user_command('ToggleAgent', function(cmd)
    M.toggle(cmd.args)
  end, { nargs = '?', complete = complete_names, desc = 'Toggle a terminal agent' })
  api.nvim_create_user_command('CloseAgent', function(cmd)
    M.close(cmd.args)
  end, { nargs = '?', complete = complete_names, desc = 'Close a terminal agent' })
end

return M
