-- Mutable session state for the currently open review.
local M = {}

function M.reset()
  M.model = nil -- see review.lua
  M.root = nil -- git repository root
  M.base = nil -- base commit the local changes are diffed against
  M.tree = nil -- tree object of the revision's files (the base with the diff applied)
  M.files = {} -- changed files `{ status, path, old_path }`, see review.lua
  M.file_set = {} -- path -> file
  M.drafts = {} -- path -> list of unsubmitted inline threads
  M.hidden = false -- inline comments hidden
  M.panel_buf = nil
  M.panel_win = nil
  M.panel_items = {}
  M.collapsed = {} -- directory path -> true when folded in the panel tree
  M.current_file = nil -- path of the file open in the main window
  M.file_key_bufs = {} -- buffers holding the buffer-local keys
  M.main_win = nil
  M.base_win = nil
  M.base_buf = nil
end

function M.active()
  return M.model ~= nil
end

function M.draft_count()
  local n = 0
  for _, list in pairs(M.drafts) do
    n = n + #list
  end
  return n
end

M.reset()

return M
