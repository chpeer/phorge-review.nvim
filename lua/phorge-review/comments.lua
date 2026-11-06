-- Renders inline comments as virtual lines in file buffers, highlights changed
-- lines, and provides the comment / submit editors.
local api = vim.api
local async = require('phorge-review.async')
local conduit = require('phorge-review.conduit')
local config = require('phorge-review.config')
local git = require('phorge-review.git')
local state = require('phorge-review.state')
local util = require('phorge-review.util')

local M = {}

local ns = api.nvim_create_namespace('phorge-review.comments')
local hl_ns = api.nvim_create_namespace('phorge-review.changes')
local editor_count = 0

-- Legacy `differential.createcomment` action names.
local ACTIONS = {
  comment = 'comment',
  accept = 'accept',
  ['request-changes'] = 'reject',
  reject = 'reject',
  resign = 'resign',
  ['plan-changes'] = 'rethink',
}

--- Repository-relative path of `buf`, or nil if it is neither a file in the
--- repo nor the revision's version of one.
function M.relpath(buf)
  if not state.root then
    return nil
  end
  local revision_path = vim.b[buf].phorge_review_path
  if revision_path then
    return revision_path
  end
  if vim.bo[buf].buftype ~= '' then
    return nil
  end
  local name = api.nvim_buf_get_name(buf)
  if name == '' then
    return nil
  end
  name = vim.fs.normalize(name)
  local prefix = state.root .. '/'
  if name:sub(1, #prefix) == prefix then
    return name:sub(#prefix + 1)
  end
end

local function thread_range(thread, nlines)
  local first = math.max(1, math.min(thread.line, nlines))
  local last = math.max(first, math.min(thread.line + thread.length - 1, nlines))
  return first, last
end

local function thread_virt_lines(thread, width, is_draft)
  local border = config.options.comment_border
  local lines = {}
  local function push(chunks)
    table.insert(chunks, 1, { border, 'PhorgeReviewBorder' })
    lines[#lines + 1] = chunks
  end
  for i, c in ipairs(thread.comments) do
    local indent = i == 1 and '' or '    '
    local header = {
      { (i == 1 and '' or '  ↳ ') .. c.author, 'PhorgeReviewAuthor' },
      { ' · ' .. util.fmt_date(c.date), 'PhorgeReviewMeta' },
    }
    if i == 1 then
      if is_draft then
        header[#header + 1] = { '  [draft]', 'PhorgeReviewDraft' }
      end
      if thread.done then
        header[#header + 1] = { '  ✓ done', 'PhorgeReviewDone' }
      end
      if thread.diff_id and state.model.diff_id and thread.diff_id ~= state.model.diff_id then
        header[#header + 1] = { ('  (on diff %d)'):format(thread.diff_id), 'PhorgeReviewStale' }
      end
    end
    push(header)
    for _, l in ipairs(util.wrap(c.text, width - vim.fn.strdisplaywidth(border .. indent))) do
      push({ { indent .. l, 'PhorgeReviewComment' } })
    end
  end
  return lines
end

local function text_width(buf)
  local width = config.options.comment_width
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    local info = vim.fn.getwininfo(win)[1]
    width = math.min(width, info.width - info.textoff - 1)
  end
  return math.max(width, 20)
end

--- Renders `items` (`{ thread = ..., is_draft = ... }`, in display order).
--- Threads anchored on the same row share one extmark so that Neovim keeps
--- the given order.
local function place(buf, items, width)
  local nlines = api.nvim_buf_line_count(buf)
  local by_row, rows = {}, {}
  for _, it in ipairs(items) do
    local first, last = thread_range(it.thread, nlines)
    for l = first, last do
      api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { line_hl_group = 'PhorgeReviewRange', priority = 20 })
    end
    local entry = by_row[last]
    if not entry then
      entry = { virt_lines = {}, draft_only = true }
      by_row[last] = entry
      rows[#rows + 1] = last
    elseif #entry.virt_lines > 0 then
      entry.virt_lines[#entry.virt_lines + 1] = { { config.options.comment_border, 'PhorgeReviewBorder' } }
    end
    vim.list_extend(entry.virt_lines, thread_virt_lines(it.thread, width, it.is_draft))
    entry.draft_only = entry.draft_only and it.is_draft
  end
  for _, row in ipairs(rows) do
    local entry = by_row[row]
    api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
      virt_lines = entry.virt_lines,
      sign_text = entry.draft_only and config.options.signs.draft or config.options.signs.comment,
      sign_hl_group = entry.draft_only and 'PhorgeReviewDraft' or 'PhorgeReviewSign',
      priority = 30,
    })
  end
end

function M.highlight_changes(buf, path)
  api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  if not state.file_set[path] then
    return
  end
  local signs = config.options.signs
  local n = api.nvim_buf_line_count(buf)
  local hunks = git.hunks(state.root, state.base, path, state.tree)
  if #hunks == 0 and state.file_set[path].status == 'A' then
    -- Untracked files have no diff against the base.
    hunks = { { old_start = 0, old_count = 0, new_start = 1, new_count = n } }
  end
  for _, h in ipairs(hunks) do
    if h.new_count == 0 then
      local row = math.min(math.max(h.new_start, 1), n)
      api.nvim_buf_set_extmark(buf, hl_ns, row - 1, 0, {
        sign_text = signs.deleted,
        sign_hl_group = 'PhorgeReviewDeleted',
        priority = 10,
      })
    else
      local kind = h.old_count == 0 and 'Added' or 'Changed'
      for l = h.new_start, math.min(h.new_start + h.new_count - 1, n) do
        api.nvim_buf_set_extmark(buf, hl_ns, l - 1, 0, {
          sign_text = kind == 'Added' and signs.added or signs.changed,
          sign_hl_group = 'PhorgeReview' .. kind,
          line_hl_group = 'PhorgeReview' .. kind .. 'Line',
          priority = 10,
        })
      end
    end
  end
end

--- Re-renders comments (and change highlights) for `buf`.
function M.refresh_buf(buf)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  if not state.active() then
    return
  end
  local path = M.relpath(buf)
  if not path then
    return
  end
  if not config.options.diff_split then
    M.highlight_changes(buf, path)
  end
  if state.hidden then
    return
  end
  local items = {}
  for _, t in ipairs(state.model.inlines[path] or {}) do
    items[#items + 1] = { thread = t, is_draft = false }
  end
  for _, t in ipairs(state.drafts[path] or {}) do
    items[#items + 1] = { thread = t, is_draft = true }
  end
  place(buf, items, text_width(buf))
end

function M.refresh_all()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      M.refresh_buf(buf)
    end
  end
end

function M.clear_all()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
    end
  end
end

function M.toggle_comments()
  state.hidden = not state.hidden
  M.refresh_all()
  require('phorge-review.ui').render_panel()
end

--- Moves the cursor to the next/previous commented line in the current buffer.
function M.jump(direction)
  local buf = api.nvim_get_current_buf()
  local cur = api.nvim_win_get_cursor(0)[1] - 1
  local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local best
  for _, m in ipairs(marks) do
    local row = m[2]
    if m[4].virt_lines then
      if direction > 0 and row > cur and (not best or row < best) then
        best = row
      elseif direction < 0 and row < cur and (not best or row > best) then
        best = row
      end
    end
  end
  if best then
    api.nvim_win_set_cursor(0, { best + 1, 0 })
  else
    util.notify('no more comments in this buffer')
  end
end

--- Whether revision `id` is still the open review, e.g. once a Conduit reply
--- arrives: it may have been closed or replaced while waiting.
local function is_current(id)
  return state.active() and not state.model.is_local and state.model.id == id
end

--- Published thread in `path` whose range contains `row`, if any.
local function thread_at(path, row)
  for _, t in ipairs(state.model.inlines[path] or {}) do
    if row >= t.line and row <= t.line + t.length - 1 then
      return t
    end
  end
end

local function thread_at_cursor()
  local path = M.relpath(api.nvim_get_current_buf())
  return path and thread_at(path, api.nvim_win_get_cursor(0)[1])
end

--- Re-renders every window showing `path`.
function M.refresh_path(path)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and M.relpath(buf) == path then
      M.refresh_buf(buf)
    end
  end
end

--- Drops local drafts that have since been published (same path, line and
--- text as a published thread), e.g. via the web UI.
function M.reconcile_drafts()
  local changed = false
  for path, list in pairs(state.drafts) do
    local kept = {}
    for _, d in ipairs(list) do
      local published = false
      for _, t in ipairs(state.model.inlines[path] or {}) do
        if t.line == d.line and t.comments[1].text == d.comments[1].text then
          published = true
          break
        end
      end
      if published then
        changed = true
      else
        kept[#kept + 1] = d
      end
    end
    state.drafts[path] = #kept > 0 and kept or nil
  end
  if changed then
    M.save_drafts()
  end
end

--- Opens the thread under the cursor (or the revision) in the browser. This is
--- also the only way to mark a thread done or delete a draft: Conduit has no
--- API for either.
function M.browse()
  if not state.active() then
    return util.notify('no review open', vim.log.levels.WARN)
  end
  if state.model.is_local then
    return util.notify('local reviews have no web page', vim.log.levels.WARN)
  end
  local url = state.model.uri
  local t = thread_at_cursor()
  if t and t.comment_id then
    url = ('%s#inline-%d'):format(url, t.comment_id)
  end
  vim.ui.open(url)
end

-- Drafts -------------------------------------------------------------------

local function drafts_file()
  if state.model.is_local then
    local key = (state.root .. '@' .. state.model.title):gsub('[^%w%.%-]', '_')
    return vim.fs.joinpath(vim.fn.stdpath('state'), 'phorge-review', ('local-%s.json'):format(key))
  end
  local c = conduit.connection() or { uri = 'unknown' }
  local host = c.uri:gsub('^%w+://', ''):gsub('[^%w%.%-]', '_')
  return vim.fs.joinpath(vim.fn.stdpath('state'), 'phorge-review', ('%s-D%d.json'):format(host, state.model.id))
end

function M.load_drafts()
  return util.read_json(drafts_file()) or {}
end

function M.save_drafts()
  util.write_json(drafts_file(), state.drafts)
end

-- Editors ------------------------------------------------------------------

local function open_editor(opts)
  editor_count = editor_count + 1
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  api.nvim_buf_set_name(buf, ('phorge-review://%s/%d'):format(opts.name, editor_count))
  api.nvim_buf_set_lines(buf, 0, -1, false, opts.initial or { '' })
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = 'markdown'
  -- The window soft-wraps; a textwidth from the user's markdown ftplugin
  -- would add hard breaks at a different column than the window edge.
  vim.bo[buf].textwidth = 0

  local width = math.min(90, vim.o.columns - 4)
  local height = math.min(opts.near_cursor and 10 or 16, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - height) / 2) - 1
  local col = math.floor((vim.o.columns - width) / 2)
  if opts.near_cursor then
    -- Place the editor just below the cursor line (above when there is no
    -- room) so the code being commented on stays visible.
    local pos = vim.fn.win_screenpos(0)
    local screen_row = pos[1] + vim.fn.winline() - 1
    local screen_col = pos[2] + vim.fn.wincol() - 1
    if screen_row + height + 2 < vim.o.lines - 2 then
      row = screen_row
    else
      row = math.max(screen_row - height - 3, 0)
    end
    col = math.max(math.min(screen_col - 1, vim.o.columns - width - 2), 0)
  end
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. opts.title .. ' ',
    title_pos = 'left',
    footer = ' :w or <C-s> to send · q to cancel ',
    footer_pos = 'right',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  local function submit()
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.bo[buf].modified = false
    close()
    opts.on_submit(lines)
  end
  api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = submit })
  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, { buffer = buf })
  if opts.insert then
    vim.cmd.startinsert()
  end
end

--- Creates a draft inline comment on lines `line1`..`line2` of the current buffer.
function M.new_comment(line1, line2)
  if not state.active() then
    return util.notify('no review open; run :Phab [D123] first', vim.log.levels.WARN)
  end
  local buf = api.nvim_get_current_buf()
  local path = M.relpath(buf)
  if not path then
    return util.notify('current buffer is not a file inside ' .. state.root, vim.log.levels.WARN)
  end
  local where = ('%s:%d%s'):format(path, line1, line2 > line1 and ('-' .. line2) or '')
  -- Conduit has no reply parameter; a new inline on the same line is shown
  -- under the existing thread by Phabricator.
  local existing = line1 == line2 and thread_at(path, line1)
  open_editor({
    name = 'comment',
    title = existing and ('Reply to %s on %s'):format(existing.comments[1].author, where) or 'Comment on ' .. where,
    insert = true,
    near_cursor = true,
    on_submit = function(lines)
      local content = vim.trim(table.concat(lines, '\n'))
      if content == '' then
        return util.notify('empty comment discarded')
      end
      local function add_draft(id)
        local draft = {
          path = path,
          line = line1,
          length = line2 - line1 + 1,
          id = id,
          code = api.nvim_buf_get_lines(buf, line1 - 1, line2, false),
          comments = { { author = 'you', text = content, date = os.time() } },
        }
        state.drafts[path] = state.drafts[path] or {}
        table.insert(state.drafts[path], draft)
        table.sort(state.drafts[path], function(a, b)
          return a.line < b.line
        end)
        M.save_drafts()
        M.refresh_path(path)
        require('phorge-review.ui').render_panel()
        util.notify(
          ('draft saved on %s (%d pending) — %s with :Phab submit'):format(
            where,
            state.draft_count(),
            state.model.is_local and 'copy' or 'publish'
          )
        )
      end
      if state.model.is_local then
        return add_draft(nil)
      end
      local id = state.model.id
      async.run(function()
        local err, res = async.await(conduit.call('differential.createinline', {
          revisionID = id,
          filePath = path,
          isNewFile = true,
          lineNumber = line1,
          -- createinline takes end - start; transaction.search reports a line count.
          lineLength = line2 - line1,
          content = content,
        }))
        if err then
          return util.notify(err, vim.log.levels.ERROR)
        end
        if is_current(id) then
          add_draft(res and res.id)
        end
      end)
    end,
  })
end

--- Formats the local drafts and `message` as a prompt for a coding agent.
local function format_local_review(message)
  local out = {
    ('Review comments on the changes against %s (`git diff %s`). Address each one; line numbers refer to the files as they were when I commented.'):format(
      state.base:sub(1, 10),
      state.base:sub(1, 10)
    ),
  }
  if message ~= '' then
    vim.list_extend(out, { '', message })
  end
  local paths = vim.tbl_keys(state.drafts)
  table.sort(paths)
  for _, path in ipairs(paths) do
    for _, d in ipairs(state.drafts[path]) do
      local where = ('%s:%d%s'):format(path, d.line, d.length > 1 and ('-' .. (d.line + d.length - 1)) or '')
      vim.list_extend(out, { '', '## ' .. where, '', '```' })
      vim.list_extend(out, d.code or {})
      vim.list_extend(out, { '```', '', d.comments[1].text })
    end
  end
  return table.concat(out, '\n') .. '\n'
end

--- Copies the local drafts and an overall message to the `+` register and
--- clears the drafts.
local function submit_local()
  local pending = state.draft_count()
  open_editor({
    name = 'submit',
    title = ('Copy review of %s (%d comment%s)'):format(state.model.title, pending, pending == 1 and '' or 's'),
    initial = { '' },
    insert = true,
    on_submit = function(lines)
      local message = vim.trim(table.concat(lines, '\n'))
      if message == '' and pending == 0 then
        return util.notify('nothing to submit')
      end
      local ok, err = pcall(vim.fn.setreg, '+', format_local_review(message))
      if not ok then
        return util.notify('could not copy to the + register: ' .. tostring(err), vim.log.levels.ERROR)
      end
      state.drafts = {}
      M.save_drafts()
      M.refresh_all()
      require('phorge-review.ui').render_panel()
      util.notify(('copied %d comment%s to the clipboard'):format(pending, pending == 1 and '' or 's'))
    end,
  })
end

--- Publishes pending drafts together with an overall comment / action.
function M.submit()
  if not state.active() then
    return util.notify('no review open', vim.log.levels.WARN)
  end
  if state.model.is_local then
    return submit_local()
  end
  local pending = state.draft_count()
  open_editor({
    name = 'submit',
    title = ('Submit review for D%d (%d draft inline%s)'):format(state.model.id, pending, pending == 1 and '' or 's'),
    initial = {
      '<!-- action: comment | accept | request-changes | resign | plan-changes -->',
      'action: comment',
      '',
      '',
    },
    on_submit = function(lines)
      local action, body = nil, {}
      for _, l in ipairs(lines) do
        local a = l:match('^action:%s*(%S+)')
        if a and not action then
          action = a
        elseif not l:match('^<!%-%-') then
          body[#body + 1] = l
        end
      end
      action = action or 'comment'
      local legacy = ACTIONS[action]
      if not legacy then
        return util.notify('unknown action "' .. action .. '"', vim.log.levels.ERROR)
      end
      local message = vim.trim(table.concat(body, '\n'))
      if message == '' and legacy == 'comment' and pending == 0 then
        return util.notify('nothing to submit')
      end
      local id = state.model.id
      async.run(function()
        local err = async.await(conduit.call('differential.createcomment', {
          revision_id = id,
          message = message,
          action = legacy,
          attach_inlines = true,
        }))
        if err then
          return util.notify(err, vim.log.levels.ERROR)
        end
        util.notify(('submitted %s with %d inline%s'):format(action, pending, pending == 1 and '' or 's'))
        if not is_current(id) then
          return
        end
        state.drafts = {}
        M.save_drafts()
        require('phorge-review').refresh()
      end)
    end,
  })
end

return M
