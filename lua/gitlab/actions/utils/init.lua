local u = require("gitlab.utils")
local state = require("gitlab.state")
local M = {}

---Build note header from note
---@param note Note
---@return string
M.build_note_header = function(note)
  return "@" .. note.author.username .. " " .. u.time_since(note.created_at)
end

---Build note header from draft note
---@return string
M.build_draft_note_header = function()
  if not state.USER then return "" end
  return " Draft note from @" .. state.USER.username
end

M.switch_can_edit_bufs = function(bool, ...)
  local bufnrs = { ... }
  ---@param v integer
  for _, v in ipairs(bufnrs) do
    u.switch_can_edit_buf(v, bool)
    vim.api.nvim_set_option_value("filetype", "gitlab", { buf = v })
  end
end

return M
