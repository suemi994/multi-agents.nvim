local api = vim.api
local M = {}

local function has_border(border, side)
  local cell = type(border) == 'table' and border[side] or nil
  if type(cell) == 'table' then
    cell = cell[1]
  end
  return cell ~= nil and cell ~= ''
end

local function float_edges(mouse, layout)
  local border = layout.border
  local top, right = has_border(border, 2), has_border(border, 4)
  local bottom, left = has_border(border, 6), has_border(border, 8)
  local width = layout.width + (left and 1 or 0) + (right and 1 or 0)
  local height = layout.height + (top and 1 or 0) + (bottom and 1 or 0)
  local x = left and mouse.wincol == 1 and -1 or right and mouse.wincol == width and 1 or 0
  local y = top and mouse.winrow == 1 and -1 or bottom and mouse.winrow == height and 1 or 0
  return x, y, width, height
end

local function start_drag(mouse, get_agent)
  local hit = mouse.winid
  if hit ~= 0 then
    local layout = api.nvim_win_get_config(hit)
    if layout.relative ~= '' then
      local agent = get_agent(hit)
      if agent and agent.mode == 'float' and layout.anchor == 'NW' then
        local x, y, width, height = float_edges(mouse, layout)
        if x ~= 0 or y ~= 0 then
          return {
            win = hit,
            agent = agent,
            x = x,
            y = y,
            layout = layout,
            width = width,
            height = height,
          }
        end
      end
      return
    end
  end

  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local agent = get_agent(win)
    if agent and agent.mode == 'vertical' and api.nvim_win_get_config(win).relative == '' then
      local row, col = unpack(api.nvim_win_get_position(win))
      local width, height = api.nvim_win_get_width(win), api.nvim_win_get_height(win)
      if mouse.screenrow > row and mouse.screenrow <= row + height then
        if col > 0 and mouse.screencol == col then
          return { win = win, agent = agent, x = -1, width = width }
        elseif col + width < vim.o.columns and mouse.screencol == col + width + 1 then
          return { win = win, agent = agent, x = 1, width = width }
        end
      end
    end
  end
end

local function resize(drag, mouse)
  local win, agent = drag.win, drag.agent
  if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= agent.buf then
    return
  end

  local dx = (mouse.screencol - drag.start.screencol) * drag.x
  if not drag.layout then
    if agent.mode == 'vertical' then
      api.nvim_win_set_width(win, math.max(1, drag.width + dx))
      agent.size = { width = api.nvim_win_get_width(win) }
    end
    return
  elseif agent.mode ~= 'float' then
    return
  end

  local dy = (mouse.screenrow - drag.start.screenrow) * drag.y
  local layout = vim.tbl_extend('force', drag.layout, {})
  local row, col = unpack(drag.position)
  local max_dx = drag.x < 0 and col or vim.o.columns - col - drag.width
  local max_dy = drag.y < 0 and row or vim.o.lines - vim.o.cmdheight - row - drag.height
  dx = math.max(1 - layout.width, math.min(dx, math.max(0, max_dx)))
  dy = math.max(1 - layout.height, math.min(dy, math.max(0, max_dy)))
  layout.width, layout.height = layout.width + dx, layout.height + dy
  layout.col = layout.col - (drag.x < 0 and dx or 0)
  layout.row = layout.row - (drag.y < 0 and dy or 0)
  api.nvim_win_set_config(win, layout)
  agent.size = { width = layout.width, height = layout.height }
end

function M.setup(get_agent)
  local press, move, release =
    vim.keycode('<LeftMouse>'), vim.keycode('<LeftDrag>'), vim.keycode('<LeftRelease>')
  local drag
  vim.on_key(function(key)
    if key == press then
      local mouse = vim.fn.getmousepos()
      drag = start_drag(mouse, get_agent)
      if drag then
        drag.start, drag.last = mouse, mouse
        drag.position = api.nvim_win_get_position(drag.win)
        return ''
      end
    elseif drag and (key == move or key == release) then
      local active, mouse = drag, vim.fn.getmousepos()
      if mouse.screenrow ~= active.last.screenrow or mouse.screencol ~= active.last.screencol then
        active.last = mouse
        vim.schedule(function()
          resize(active, mouse)
        end)
      end
      if key == release then
        drag = nil
      end
      return ''
    end
  end, api.nvim_create_namespace('multi-agents-resize'))
end

return M
