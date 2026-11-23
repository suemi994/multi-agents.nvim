local agents = require('multi-agents.agents')
local config = require('claude-code.config')

local M = {
  open = agents.open,
  list = agents.list,
  toggle = agents.toggle,
  close = agents.close,
}

function M.setup(opts)
  agents.setup(config.parse_config(opts))
end

return M
