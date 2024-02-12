-- This Module contains all of the reviewer code for diffview
local u = require("gitlab.utils")
local state = require("gitlab.state")
local async_ok, async = pcall(require, "diffview.async")
local diffview_lib = require("diffview.lib")

local M = {
  bufnr = nil,
  tabnr = nil,
}

local all_git_manged_files_unmodified = function()
  -- check local managed files are unmodified, matching the state in the MR
  -- TODO: ensure correct CWD?
  return vim.fn.trim(vim.fn.system({ "git", "status", "--short", "--untracked-files=no" })) == ""
end

M.open = function()
  local diff_refs = state.INFO.diff_refs
  if diff_refs == nil then
    u.notify("Gitlab did not provide diff refs required to review this MR", vim.log.levels.ERROR)
    return
  end

  if diff_refs.base_sha == "" or diff_refs.head_sha == "" then
    u.notify("Merge request contains no changes", vim.log.levels.ERROR)
    return
  end

  local diffview_open_command = "DiffviewOpen"
  local diffview_feature_imply_local = {
    user_requested = state.settings.reviewer_settings.diffview.imply_local,
    usable = all_git_manged_files_unmodified(),
  }
  if diffview_feature_imply_local.user_requested and diffview_feature_imply_local.usable then
    diffview_open_command = diffview_open_command .. " --imply-local"
  end

  vim.api.nvim_command(string.format("%s %s..%s", diffview_open_command, diff_refs.base_sha, diff_refs.head_sha))
  M.tabnr = vim.api.nvim_get_current_tabpage()

  if diffview_feature_imply_local.user_requested and not diffview_feature_imply_local.usable then
    u.notify(
      "There are uncommited changes in the working tree, cannot use 'imply_local' setting for gitlab reviews. Stash or commit all changes to use.",
      vim.log.levels.WARN
    )
  end

  if state.INFO.has_conflicts then
    u.notify("This merge request has conflicts!", vim.log.levels.WARN)
  end

  -- Register Diffview hook for close event to set tab page # to nil
  local on_diffview_closed = function(view)
    if view.tabpage == M.tabnr then
      M.tabnr = nil
    end
  end
  require("diffview.config").user_emitter:on("view_closed", function(_, ...)
    on_diffview_closed(...)
  end)

  if state.settings.discussion_tree.auto_open then
    local discussions = require("gitlab.actions.discussions")
    discussions.close()
    discussions.toggle()
  end
end

M.close = function()
  vim.cmd("DiffviewClose")
  local discussions = require("gitlab.actions.discussions")
  discussions.close()
end

M.jump = function(file_name, new_line, old_line, opts)
  if M.tabnr == nil then
    u.notify("Can't jump to Diffvew. Is it open?", vim.log.levels.ERROR)
    return
  end
  vim.api.nvim_set_current_tabpage(M.tabnr)
  vim.cmd("DiffviewFocusFiles")
  local view = diffview_lib.get_current_view()
  if view == nil then
    u.notify("Could not find Diffview view", vim.log.levels.ERROR)
    return
  end
  local files = view.panel:ordered_file_list()
  local layout = view.cur_layout
  for _, file in ipairs(files) do
    if file.path == file_name then
      if not async_ok then
        u.notify("Could not load Diffview async", vim.log.levels.ERROR)
        return
      end
      async.await(view:set_file(file))
      -- TODO: Ranged comments on unchanged lines will have both a
      -- new line and a old line.
      --
      -- The same is true when the user leaves a single-line comment
      -- on an unchanged line in the "b" buffer.
      --
      -- We need to distinguish them somehow from
      -- range comments (which also have this) so that we can know
      -- which buffer to jump to. Right now, we jump to the wrong
      -- buffer for ranged comments on unchanged lines.
      if new_line ~= nil and not opts.is_undefined_type then
        layout.b:focus()
        vim.api.nvim_win_set_cursor(0, { tonumber(new_line), 0 })
      elseif old_line ~= nil then
        layout.a:focus()
        vim.api.nvim_win_set_cursor(0, { tonumber(old_line), 0 })
      end
      break
    end
  end
end

---Get the location of a line within the diffview. If range is specified, then also the location
---of the lines in range.
---@param range LineRange | nil Line range to get location for
---@return ReviewerInfo | nil nil is returned only if error was encountered
M.get_location = function(range)
  if M.tabnr == nil then
    u.notify("Diffview reviewer must be initialized first", vim.log.levels.ERROR)
    return
  end

  -- If there's a range, use the start of the visual selection, not the current line
  local current_line = range and range.start_line or vim.api.nvim_win_get_cursor(0)[1]

  -- Check if we are in the diffview tab
  local tabnr = vim.api.nvim_get_current_tabpage()
  if tabnr ~= M.tabnr then
    u.notify("Line location can only be determined within reviewer window", vim.log.levels.ERROR)
    return
  end

  -- Check if we are in the diffview buffer
  local view = diffview_lib.get_current_view()
  if view == nil then
    u.notify("Could not find Diffview view", vim.log.levels.ERROR)
    return
  end

  local layout = view.cur_layout

  --- After ensuring that we are in the reviewer, we must build the API call correctly for Gitlab.
  --- If this is a comment on a deleted or unchanged line, we want to send the new and old line.
  --- Otherwise (if the line is new or a modified line) we want to send the new line only.
  ---@type ReviewerInfo
  local reviewer_info = {
    file_name = layout.a.file.path,
    new_line = nil,
    old_line = nil,
    range_info = nil,
  }

  -- Check if we are getting line number from new or old version of the file
  -- Depending on what we're doing, we need to modify the payload. With Diffview,
  -- our scrolling is locked so we can easily get both line numbers using the
  -- nvim_win_get_cursor function.

  -- If we are in the "b" buffer, which is the current version of the file, then we want to
  -- only send the new line number. The only exception here is if we are trying to make a comment
  -- on an unchanged line, in which case we actually want to send both, per Gitlab's janky API.

  local a_win = u.get_window_id_by_buffer_id(layout.a.file.bufnr)
  local b_win = u.get_window_id_by_buffer_id(layout.b.file.bufnr)
  local current_win = vim.fn.win_getid()
  local is_current_sha = current_win == b_win

  if a_win == nil or b_win == nil then
    u.notify("Error retrieving window IDs for current files", vim.log.levels.ERROR)
    return
  end

  local current_file = M.get_current_file()
  if current_file == nil then
    u.notify("Error retrieving current file from Diffview", vim.log.levels.ERROR)
    return
  end

  local a_linenr = vim.api.nvim_win_get_cursor(a_win)[1]
  local b_linenr = vim.api.nvim_win_get_cursor(b_win)[1]

  local data = u.parse_hunk_headers(current_file, state.INFO.target_branch)

  -- Will be different depending on focused window.
  local modification_type = M.get_modification_type(a_linenr, b_linenr, is_current_sha, data.hunks, data.all_diff_output)

  if modification_type == nil then
    u.notify("Comments on unchanged lines must be left in the old file", vim.log.levels.WARN)
    return
  end

  -- Comment on new line, or comment on modified line (Gitlab splits these
  -- lines into red/green, commenter was focused on new SHA): Include only new_line in payload.
  if modification_type == "added" or (modification_type == "modified" and is_current_sha) then
    reviewer_info.old_line = nil
    reviewer_info.new_line = b_linenr
    -- Comment on deleted line, or comment on modified line and commenter
    -- was focused on the old SHA: Include only new_line in payload.
  elseif modification_type == "deleted" or (modification_type == "modified" and is_current_sha) then
    reviewer_info.old_line = a_linenr
    reviewer_info.new_line = nil
    -- The line was not found in any hunks, only send the old line number
  elseif modification_type == "unmodified" then
    reviewer_info.old_line = a_linenr
    reviewer_info.new_line = b_linenr
  end

  if range == nil then
    return reviewer_info
  end

  -- If leaving a multi-line comment, we want to also add range_info to the payload.
  if data.hunks == nil then
    u.notify("Could not parse hunks", vim.log.levels.ERROR)
    return
  end

  local is_new = reviewer_info.new_line ~= nil
  local current_line_info = is_new and u.get_lines_from_hunks(data.hunks, reviewer_info.new_line, is_new) or
      u.get_lines_from_hunks(data.hunks, reviewer_info.old_line, is_new)
  local type = is_new and "new" or "old"

  ---@type ReviewerRangeInfo
  local range_info = { start = {},["end"] = {} }

  if current_line == range.start_line then
    range_info.start.old_line = current_line_info.old_line
    range_info.start.new_line = current_line_info.new_line
    range_info.start.type = type
  else
    local start_line_info = u.get_lines_from_hunks(data.hunks, range.start_line, is_new)
    range_info.start.old_line = start_line_info.old_line
    range_info.start.new_line = start_line_info.new_line
    range_info.start.type = type
  end
  if current_line == range.end_line then
    range_info["end"].old_line = current_line_info.old_line
    range_info["end"].new_line = current_line_info.new_line
    range_info["end"].type = type
  else
    local end_line_info = u.get_lines_from_hunks(data.hunks, range.end_line, is_new)
    range_info["end"].old_line = end_line_info.old_line
    range_info["end"].new_line = end_line_info.new_line
    range_info["end"].type = type
  end

  reviewer_info.range_info = range_info
  return reviewer_info
end

---Return content between start_line and end_line
---@param start_line integer
---@param end_line integer
---@return string[]
M.get_lines = function(start_line, end_line)
  return vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
end

---Checks whether the lines in the two buffers are the same
---@return boolean
M.lines_are_same = function(layout, a_cursor, b_cursor)
  local line_a = u.get_line_content(layout.a.file.bufnr, a_cursor)
  local line_b = u.get_line_content(layout.b.file.bufnr, b_cursor)
  return line_a == line_b
end

---Get currently shown file
M.get_current_file = function()
  local view = diffview_lib.get_current_view()
  if not view then
    return
  end
  return view.panel.cur_file.path
end

---Place a sign in currently reviewed file. Use new line for identifing lines after changes, old
---line for identifing lines before changes and both if line was not changed.
---@param signs SignTable[] table of signs. See :h sign_placelist
---@param type string "new" if diagnostic should be in file after changes else "old"
M.place_sign = function(signs, type)
  local view = diffview_lib.get_current_view()
  if not view then
    return
  end
  if type == "new" then
    for _, sign in ipairs(signs) do
      sign.buffer = view.cur_layout.b.file.bufnr
    end
  elseif type == "old" then
    for _, sign in ipairs(signs) do
      sign.buffer = view.cur_layout.a.file.bufnr
    end
  end
  vim.fn.sign_placelist(signs)
end

---Set diagnostics in currently reviewed file.
---@param namespace integer namespace for diagnostics
---@param diagnostics table see :h vim.diagnostic.set
---@param type string "new" if diagnostic should be in file after changes else "old"
---@param opts table? see :h vim.diagnostic.set
M.set_diagnostics = function(namespace, diagnostics, type, opts)
  local view = diffview_lib.get_current_view()
  if not view then
    return
  end
  if type == "new" and view.cur_layout.b.file.bufnr then
    vim.diagnostic.set(namespace, view.cur_layout.b.file.bufnr, diagnostics, opts)
  elseif type == "old" and view.cur_layout.a.file.bufnr then
    vim.diagnostic.set(namespace, view.cur_layout.a.file.bufnr, diagnostics, opts)
  end
end

---Diffview exposes events which can be used to setup autocommands.
---@param callback fun(opts: table) - for more information about opts see callback in :h nvim_create_autocmd
M.set_callback_for_file_changed = function(callback)
  local group = vim.api.nvim_create_augroup("gitlab.diffview.autocommand.file_changed", {})
  vim.api.nvim_create_autocmd("User", {
    pattern = { "DiffviewDiffBufWinEnter", "DiffviewViewEnter" },
    group = group,
    callback = function(...)
      if M.tabnr == vim.api.nvim_get_current_tabpage() then
        callback(...)
      end
    end,
  })
end

---Diffview exposes events which can be used to setup autocommands.
---@param callback fun(opts: table) - for more information about opts see callback in :h nvim_create_autocmd
M.set_callback_for_reviewer_leave = function(callback)
  local group = vim.api.nvim_create_augroup("gitlab.diffview.autocommand.leave", {})
  vim.api.nvim_create_autocmd("User", {
    pattern = { "DiffviewViewLeave", "DiffviewViewClosed" },
    group = group,
    callback = function(...)
      if M.tabnr == vim.api.nvim_get_current_tabpage() then
        callback(...)
      end
    end,
  })
end

---Returns whether the comment is on a new_line, changed line, deleted line, or unmodified line
---@param a_linenr number
---@param b_linenr number
---@param is_current_sha boolean
---@param hunks Hunk[] A list of hunks
---@param all_diff_output table The raw diff output
function M.get_modification_type(a_linenr, b_linenr, is_current_sha, hunks, all_diff_output)
  -- If leaving a comment on the old window, we can either be commenting
  -- on a deletion, a modified line, or an unmodified line. It's a deletion if it's in the range.
  if not is_current_sha then
    for _, hunk in ipairs(hunks) do
      local old_line_end = hunk.old_line + hunk.old_range
      if a_linenr >= hunk.old_line and a_linenr <= old_line_end and hunk.new_range == 0 then
        return "deleted"
      end
      local new_line_end = hunk.new_line + hunk.new_range
      if a_linenr >= hunk.new_line and b_linenr <= new_line_end then
        -- TODO: This might fail in certain circumstances where the line number from the
        -- old SHA falls in the range of a hunk that is actually only adding lines...
        return "deleted"
      end
    end
  else
    -- If commenting on the new window, we are either leaving a comment on a modified
    -- line or an added line.
    for _, hunk in ipairs(hunks) do
      local new_line_end = hunk.new_line + hunk.new_range
      if b_linenr >= hunk.new_line and b_linenr <= new_line_end then
        -- TODO: Check if the actual hunk content that it matches has been added.
        -- If so, mark it as added. Otherwise, mark it as modified.
        return "modified"
      end
    end

    -- If we can't find the line, this means the user is trying to leave a comment on an unmodified
    -- line, but in the new buffer. Warn them and do not post the comment.
    return nil
  end

  -- If the line number does not fall within any hunk ranges, it is unmodified
  return "unmodified"
end

return M
