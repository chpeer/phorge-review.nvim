-- Side panel (files, comments, timeline), diff split and description float.
local api = vim.api
local config = require('phorge-review.config')
local git = require('phorge-review.git')
local state = require('phorge-review.state')
local util = require('phorge-review.util')

local M = {}

local panel_ns = api.nvim_create_namespace('phorge-review.panel')

local STATUS_HL = {
  M = 'PhorgeReviewChanged',
  A = 'PhorgeReviewAdded',
  D = 'PhorgeReviewDeleted',
  R = 'PhorgeReviewChanged',
  C = 'PhorgeReviewAdded',
}

local REVIEWER_MARK = {
  accepted = '✓',
  rejected = '✗',
  blocking = '!',
  added = '·',
  resigned = '-',
}

local function win_valid(win)
  return win and api.nvim_win_is_valid(win)
end

local function buf_valid(buf)
  return buf and api.nvim_buf_is_valid(buf)
end

--- A window of the review tab suitable for showing review files: not the panel
--- or base split, not floating, not a terminal/prompt/quickfix window.
local function is_file_win(win)
  return win_valid(win)
    and api.nvim_win_get_tabpage(win) == state.tabpage
    and win ~= state.panel_win
    and win ~= state.base_win
    and api.nvim_win_get_config(win).relative == ''
    and not vim.tbl_contains({ 'terminal', 'prompt', 'quickfix' }, vim.bo[api.nvim_win_get_buf(win)].buftype)
end

-- Panel ---------------------------------------------------------------------

--- Builds a directory tree from the changed files. Directories with a single
--- subdirectory and no files are merged into one node ("a/b/c").
--- Returns `{ dirs = { { name, path, dirs, files } }, files = { file } }`.
function M.file_tree(files)
  local root = { name = '', path = '', dirs = {}, files = {}, index = {} }
  for _, f in ipairs(files) do
    local node = root
    local parts = vim.split(f.path, '/', { plain = true })
    for i = 1, #parts - 1 do
      local child = node.index[parts[i]]
      if not child then
        child = {
          name = parts[i],
          path = (node.path == '' and '' or node.path .. '/') .. parts[i],
          dirs = {},
          files = {},
          index = {},
        }
        node.index[parts[i]] = child
        node.dirs[#node.dirs + 1] = child
      end
      node = child
    end
    node.files[#node.files + 1] = f
  end
  local function compact(node)
    for i, dir in ipairs(node.dirs) do
      while #dir.dirs == 1 and #dir.files == 0 do
        local only = dir.dirs[1]
        dir = { name = dir.name .. '/' .. only.name, path = only.path, dirs = only.dirs, files = only.files }
        node.dirs[i] = dir
      end
      compact(dir)
    end
    table.sort(node.dirs, function(a, b)
      return a.name < b.name
    end)
    table.sort(node.files, function(a, b)
      return a.path < b.path
    end)
  end
  compact(root)
  return root
end

local function panel_keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, desc = 'phorge-review: ' .. desc })
  end
  map('<CR>', M.panel_select, 'open item under cursor')
  map('o', M.panel_select, 'open item under cursor')
  map('d', M.description, 'show description')
  map('s', function()
    require('phorge-review.comments').submit()
  end, 'submit review')
  map('R', function()
    require('phorge-review').refresh()
  end, 'refresh')
  map('t', function()
    require('phorge-review.comments').toggle_comments()
  end, 'toggle inline comments')
  map('q', function()
    require('phorge-review').close()
  end, 'close review')
  map('?', M.help, 'show help')
end

local ACTION_HELP = {
  { 'comment', 'comment on line / visual selection (reply when on a thread)' },
  { 'submit', 'publish drafts with a message and action' },
  { 'next', 'next comment in buffer' },
  { 'prev', 'previous comment in buffer' },
  { 'toggle_comments', 'hide / show inline comments' },
  { 'browse', 'open thread or revision in the browser' },
  { 'files', 'focus the panel' },
}

--- Shows the configured keys and panel keys in a floating window.
function M.help()
  local keymaps = config.options.keymaps or {}
  local lines = { 'Global keys', '' }
  for _, a in ipairs(ACTION_HELP) do
    local lhs = keymaps[a[1]]
    lines[#lines + 1] = ('  %-12s %-22s %s'):format(lhs or '-', ':Phab ' .. a[1]:gsub('_', '-'), a[2])
  end
  vim.list_extend(lines, {
    '',
    'Panel keys',
    '',
    '  <CR> / o     open file, fold directory, jump to thread',
    '  d            description, test plan and timeline',
    '  s            submit review',
    '  t            toggle inline comments',
    '  R            refresh',
    '  q            close review',
    '  ?            this help',
    '',
    'Editors: :w or <C-s> sends, q cancels.   Full docs: :help phorge-review',
  })
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' phorge-review ',
    footer = ' q to close ',
    footer_pos = 'right',
  })
  for i, l in ipairs(lines) do
    if l ~= '' and not l:match('^%s') then
      api.nvim_buf_set_extmark(buf, panel_ns, i - 1, 0, { end_col = #l, hl_group = 'PhorgeReviewSection' })
    end
  end
  vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = buf, nowait = true })
  vim.keymap.set('n', '?', '<Cmd>close<CR>', { buffer = buf, nowait = true })
  return win
end

function M.render_panel()
  local buf = state.panel_buf
  if not buf_valid(buf) or not state.active() then
    return
  end
  local m = state.model
  local lines, items, hls = {}, {}, {}
  local function add(text, item, hl, col_end)
    -- Buffer lines cannot contain newlines, and server fields such as the
    -- title may.
    lines[#lines + 1] = (text:gsub('[\r\n]+', ' '))
    items[#lines] = item
    if hl then
      hls[#hls + 1] = { #lines, hl, col_end }
    end
  end
  local function section(title)
    add('')
    add(title, nil, 'PhorgeReviewSection')
  end

  if m.is_local then
    add('local review · ' .. m.title, nil, 'PhorgeReviewTitle')
    add(
      ('base %s%s'):format((state.base or ''):sub(1, 10), m.ref and (' (merge base with %s)'):format(m.ref) or ''),
      nil,
      'PhorgeReviewMeta'
    )
  else
    add(('D%d · %s · %s'):format(m.id, m.status, m.author), { kind = 'description' }, 'PhorgeReviewTitle')
    add(m.title, { kind = 'description' })
    local rv = {}
    for _, r in ipairs(m.reviewers) do
      rv[#rv + 1] = (REVIEWER_MARK[r.status] or '·') .. r.name
    end
    add('reviewers: ' .. (#rv > 0 and table.concat(rv, ' ') or 'none'), { kind = 'description' }, 'PhorgeReviewMeta')
    add(('base %s · diff %s'):format((state.base or ''):sub(1, 10), tostring(m.diff_id)), nil, 'PhorgeReviewMeta')
  end
  if state.hidden then
    add('inline comments hidden — press t to show', nil, 'PhorgeReviewDraft')
  end

  section(('Files (%d)'):format(#state.files))
  local function add_file(f, indent, label)
    local n = #(m.inlines[f.path] or {})
    local d = #(state.drafts[f.path] or {})
    local suffix = (n > 0 and ('  %s%d'):format(config.options.signs.comment, n) or '')
      .. (d > 0 and ('  %s%d'):format(config.options.signs.draft, d) or '')
    add(
      ('%s%s %s%s'):format(indent, f.status, label, suffix),
      { kind = 'file', file = f },
      STATUS_HL[f.status],
      #indent + 1
    )
  end
  if config.options.panel.tree then
    local function render_dir(node, depth)
      local indent = string.rep('  ', depth)
      for _, dir in ipairs(node.dirs) do
        local collapsed = state.collapsed[dir.path]
        add(
          ('%s%s %s/'):format(indent, collapsed and '▸' or '▾', dir.name),
          { kind = 'dir', path = dir.path },
          'PhorgeReviewDir'
        )
        if not collapsed then
          render_dir(dir, depth + 1)
        end
      end
      for _, f in ipairs(node.files) do
        add_file(f, indent, vim.fs.basename(f.path))
      end
    end
    render_dir(M.file_tree(state.files), 0)
  else
    for _, f in ipairs(state.files) do
      add_file(f, ' ', f.path)
    end
  end

  local threads = {}
  for path, list in pairs(m.inlines) do
    for _, t in ipairs(list) do
      threads[#threads + 1] = { path = path, thread = t }
    end
  end
  table.sort(threads, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    if a.thread.line ~= b.thread.line then
      return a.thread.line < b.thread.line
    end
    return (a.thread.comments[1].date or 0) < (b.thread.comments[1].date or 0)
  end)
  if not m.is_local then
    section(('Inline comments (%d)'):format(#threads))
    for _, it in ipairs(threads) do
      local c = it.thread.comments[1]
      add(
        ('  %s:%d %s: %s'):format(vim.fs.basename(it.path), it.thread.line, c.author, util.one_line(c.text, 60)),
        { kind = 'thread', path = it.path, thread = it.thread },
        it.thread.done and 'PhorgeReviewDone' or nil
      )
    end
  end

  local drafts = state.draft_count()
  if drafts > 0 then
    section(('Drafts (%d) — `s` to %s'):format(drafts, m.is_local and 'copy' or 'submit'))
    for path, list in pairs(state.drafts) do
      for _, t in ipairs(list) do
        add(
          ('  %s:%d %s'):format(vim.fs.basename(path), t.line, util.one_line(t.comments[1].text, 60)),
          { kind = 'thread', path = path, thread = t },
          'PhorgeReviewDraft'
        )
      end
    end
  end

  if m.is_local then
    add('')
    add('<CR> open · s copy review · R refresh · q close · ? help', nil, 'PhorgeReviewMeta')
  else
    section('Timeline')
    local first = math.max(1, #m.timeline - config.options.panel_timeline + 1)
    for i = first, #m.timeline do
      local e = m.timeline[i]
      add(
        ('  %s %s'):format(e.author, e.action or util.one_line(e.text, 60)),
        { kind = 'description' },
        e.action and 'PhorgeReviewMeta' or nil
      )
    end

    add('')
    add('<CR> open · d description · s submit · R refresh · q close · ? help', nil, 'PhorgeReviewMeta')
  end

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, panel_ns, 0, -1)
  for _, h in ipairs(hls) do
    api.nvim_buf_set_extmark(buf, panel_ns, h[1] - 1, 0, {
      end_col = h[3] or #lines[h[1]],
      hl_group = h[2],
    })
  end
  state.panel_items = items
end

function M.open_panel()
  if not state.active() then
    return util.notify('no review open; run :Phab [D123] first', vim.log.levels.WARN)
  end
  if win_valid(state.panel_win) then
    api.nvim_set_current_win(state.panel_win)
    return
  end
  local new_tab = not (state.tabpage and api.nvim_tabpage_is_valid(state.tabpage))
  if not new_tab then
    api.nvim_set_current_tabpage(state.tabpage)
  else
    -- The review gets its own tab so that it leaves the layout of the others
    -- alone; closing the review closes the tab.
    vim.cmd('tab split')
    state.tabpage = api.nvim_get_current_tabpage()
  end
  local cur = api.nvim_get_current_win()
  if is_file_win(cur) then
    state.main_win = cur
  end
  if not buf_valid(state.panel_buf) then
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
    api.nvim_buf_set_name(buf, 'phorge-review://panel')
    vim.bo[buf].filetype = 'phorge-review'
    panel_keymaps(buf)
    state.panel_buf = buf
  end
  vim.cmd(('topleft %dvsplit'):format(config.options.panel.width))
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, state.panel_buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].winfixwidth = true
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].list = false
  vim.wo[win].spell = false
  state.panel_win = win
  M.render_panel()
  if new_tab then
    -- A new tab shows the first file the panel lists, with the panel cursor on
    -- its entry.
    for row = 1, api.nvim_buf_line_count(state.panel_buf) do
      local item = state.panel_items[row]
      if item and item.kind == 'file' then
        M.open_file(item.file)
        api.nvim_set_current_win(state.panel_win)
        api.nvim_win_set_cursor(state.panel_win, { row, 0 })
        break
      end
    end
  end
end

function M.panel_select()
  local item = state.panel_items[api.nvim_win_get_cursor(0)[1]]
  if not item then
    return
  end
  if item.kind == 'file' then
    M.open_file(item.file)
  elseif item.kind == 'dir' then
    state.collapsed[item.path] = not state.collapsed[item.path] or nil
    local row = api.nvim_win_get_cursor(0)[1]
    M.render_panel()
    api.nvim_win_set_cursor(0, { row, 0 })
  elseif item.kind == 'thread' then
    M.open_file(state.file_set[item.path] or { status = 'M', path = item.path })
    local n = api.nvim_buf_line_count(0)
    api.nvim_win_set_cursor(0, { math.min(item.thread.line, n), 0 })
    vim.cmd('normal! zz')
  elseif item.kind == 'description' then
    M.description()
  end
end

-- File / diff windows ---------------------------------------------------------

local function main_win()
  if is_file_win(state.main_win) then
    return state.main_win
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(state.tabpage)) do
    if is_file_win(win) then
      state.main_win = win
      return win
    end
  end
  api.nvim_set_current_win(state.panel_win)
  vim.cmd('rightbelow vnew')
  vim.cmd('wincmd =')
  state.main_win = api.nvim_get_current_win()
  return state.main_win
end

local diff_group = api.nvim_create_augroup('phorge-review.diff', { clear = true })

local function close_base()
  api.nvim_clear_autocmds({ group = diff_group })
  if win_valid(state.base_win) then
    api.nvim_win_close(state.base_win, true)
  end
  if buf_valid(state.base_buf) then
    api.nvim_buf_delete(state.base_buf, { force = true })
  end
  state.base_win, state.base_buf = nil, nil
end

--- Shows `content`, the base version of `path` or, with `revision`, the
--- revision's version, in `win`. A revision buffer stands in for the file of
--- the same path: comments are placed on it.
local function base_buffer(win, path, content, revision)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content:gsub('\n$', ''), '\n', { plain = true }))
  if revision then
    vim.b[buf].phorge_review_path = path
  end
  -- Show the buffer before naming it, so that a buffer `win` showed before
  -- (e.g. of the same file) is wiped and its name is free.
  api.nvim_win_set_buf(win, buf)
  api.nvim_buf_set_name(buf, ('phorge-review://%s/%s'):format(revision and 'revision' or 'base', path))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  local ft = vim.filetype.match({ filename = path, buf = buf })
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

--- Shows `base_content`, the base version of `file`, in a diff split left of
--- `main`, the current window, which shows `file_buf`.
local function diff_split(main, file, file_buf, base_content)
  vim.cmd('leftabove vsplit')
  local win = api.nvim_get_current_win()
  local buf = base_buffer(win, file.old_path or file.path, base_content)
  vim.cmd.diffthis()
  state.base_win, state.base_buf = win, buf
  api.nvim_set_current_win(main)
  vim.cmd.diffthis()
  if not config.options.diff_folds then
    vim.wo[win].foldenable = false
    vim.wo[main].foldenable = false
  end
  -- 'diff' is window-local: once the main window shows another buffer (:e,
  -- gf, a picker), drop the split so it is not diffed against this base.
  api.nvim_create_autocmd('BufWinEnter', {
    group = diff_group,
    callback = function(ev)
      if api.nvim_get_current_win() == main and ev.buf ~= file_buf then
        close_base()
        vim.cmd.diffoff()
      end
    end,
  })
end

--- Opens `file` (an entry of `model.files`, see review.lua) in the main
--- window, with the base version in a diff split when configured.
function M.open_file(file)
  if not state.active() then
    return
  end
  local main = main_win()
  close_base()
  api.nvim_set_current_win(main)
  vim.cmd.diffoff()

  local base_content
  if file.status ~= 'A' then
    base_content = git.show(state.root, state.base, file.old_path or file.path)
  end

  if file.status == 'D' then
    if base_content then
      base_buffer(main, file.path, base_content)
    end
    return
  end

  -- The BufReadPost/BufWinEnter autocommands would render the comments before
  -- the split exists; the refresh_buf() at the end does it once instead.
  local path = vim.fs.joinpath(state.root, file.path)
  local tree_content = state.tree and git.show(state.root, state.tree, file.path)
  local file_buf
  M.opening = true
  if tree_content and tree_content ~= util.read_file(path) then
    file_buf = base_buffer(main, file.path, tree_content, true)
  else
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    if not ok then
      M.opening = false
      error(err, 0)
    end
    file_buf = api.nvim_get_current_buf()
  end
  M.opening = false
  if
    not state.model.is_local
    and not state.tree
    and base_content
    and base_content == table.concat(api.nvim_buf_get_lines(file_buf, 0, -1, false), '\n') .. '\n'
  then
    util.notify(
      ('%s is identical to base %s; the revision is not in your working tree (try :Phab patch D%d)'):format(
        file.path,
        state.base:sub(1, 10),
        state.model.id
      ),
      vim.log.levels.WARN
    )
  end

  if config.options.diff_split and base_content then
    diff_split(main, file, file_buf, base_content)
    -- `]c` moves to the next change after the cursor, skipping one on line 1.
    vim.cmd('normal! gg')
    if vim.fn.diff_hlID(1, 1) == 0 then
      vim.cmd('normal! ]c')
    end
  end
  require('phorge-review.comments').refresh_buf(file_buf)
end

--- Rebuilds the diff split when a changed file of the review comes back to the
--- main window without it, e.g. with <C-o> after jumping to another file.
function M.reopen_split(buf)
  if M.opening or not config.options.diff_split or api.nvim_get_current_win() ~= state.main_win then
    return
  end
  local path = require('phorge-review.comments').relpath(buf)
  local file = path and state.file_set[path]
  if not file or file.status == 'A' or file.status == 'D' then
    return
  end
  local main = state.main_win
  -- Scheduled: the BufWinEnter that drops the split of the previous file runs
  -- after this one, and splitting during a jump is unreliable.
  vim.schedule(function()
    if
      not state.active()
      or win_valid(state.base_win)
      or api.nvim_get_current_win() ~= main
      or api.nvim_win_get_buf(main) ~= buf
    then
      return
    end
    local base_content = git.show(state.root, state.base, file.old_path or file.path)
    if base_content then
      local view = vim.fn.winsaveview()
      diff_split(main, file, buf, base_content)
      vim.fn.winrestview(view)
    end
  end)
end

-- Description -----------------------------------------------------------------

local function description_lines(m)
  local lines = {
    ('# D%d: %s'):format(m.id, (m.title:gsub('[\r\n]+', ' '))),
    '',
    ('%s · %s · %s'):format(m.author, m.status, m.uri or ''),
  }
  local rv = {}
  for _, r in ipairs(m.reviewers) do
    rv[#rv + 1] = ('%s (%s%s)'):format(r.name, r.status, r.blocking and ', blocking' or '')
  end
  lines[#lines + 1] = 'Reviewers: ' .. (#rv > 0 and table.concat(rv, ', ') or 'none')
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Summary'
  lines[#lines + 1] = ''
  vim.list_extend(lines, vim.split(m.summary, '\n', { plain = true }))
  if m.test_plan ~= '' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## Test Plan'
    lines[#lines + 1] = ''
    vim.list_extend(lines, vim.split(m.test_plan, '\n', { plain = true }))
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Timeline'
  lines[#lines + 1] = ''
  for _, e in ipairs(m.timeline) do
    if e.action then
      lines[#lines + 1] = ('- %s **%s** %s'):format(util.fmt_date(e.date), e.author, e.action)
    else
      local body = vim.split(e.text, '\n', { plain = true })
      lines[#lines + 1] = ('- %s **%s**: %s'):format(util.fmt_date(e.date), e.author, body[1])
      for i = 2, #body do
        lines[#lines + 1] = '  ' .. body[i]
      end
    end
  end
  return lines
end

function M.description()
  if not state.active() then
    return util.notify('no review open', vim.log.levels.WARN)
  end
  if state.model.is_local then
    return util.notify('local reviews have no description', vim.log.levels.WARN)
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, description_lines(state.model))
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'markdown'
  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(math.max(api.nvim_buf_line_count(buf), 10), vim.o.lines - 4)
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = (' D%d '):format(state.model.id),
    footer = ' q to close ',
    footer_pos = 'right',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = buf, nowait = true })
end

function M.close()
  close_base()
  -- Cleared first so that the TabClosed autocommand does not close again.
  local tab = state.tabpage
  state.tabpage = nil
  if tab and api.nvim_tabpage_is_valid(tab) then
    if #api.nvim_list_tabpages() == 1 then
      vim.cmd('tabnew')
    end
    vim.cmd(('tabclose! %d'):format(api.nvim_tabpage_get_number(tab)))
  end
  if buf_valid(state.panel_buf) then
    api.nvim_buf_delete(state.panel_buf, { force = true })
  end
  if win_valid(state.main_win) then
    api.nvim_win_call(state.main_win, function()
      vim.cmd.diffoff()
    end)
  end
  require('phorge-review.comments').clear_all()
  state.reset()
end

return M
