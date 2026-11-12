local h = require('helpers')
local comments = require('phorge-review.comments')
local state = require('phorge-review.state')
local ui = require('phorge-review.ui')

--- Comments `text` on lines `line1`..`line2` of `path`.
local function comment(path, line1, line2, text)
  ui.open_file(state.file_set[path])
  comments.new_comment(line1, line2)
  h.submit_editor({ text })
end

local function stub_clipboard()
  local copied = {}
  h.stub(vim.fn, 'setreg', function(reg, text)
    copied[reg] = text
  end)
  return copied
end

return {
  {
    'lists the branch changes against the merge base with the default branch',
    function()
      local dir = h.feature_repo()
      vim.cmd('Phab local')
      h.eq({
        { status = 'M', path = 'a.txt' },
        { status = 'R', path = 'c.txt', old_path = 'b.txt' },
        { status = 'D', path = 'd.txt' },
        { status = 'A', path = 'new.txt' },
      }, state.files)
      h.eq(h.git(dir, 'merge-base', 'master', 'HEAD'), state.base)
      h.eq({ 'local review · feature' }, vim.api.nvim_buf_get_lines(state.panel_buf, 0, 1, false))
    end,
  },
  {
    'falls back to the next default branch when one has no common history',
    function()
      local dir = h.repo()
      h.write(dir, 'a.txt', 'unrelated\n')
      h.git(dir, 'add', '.')
      h.git(dir, 'commit', '-qm', 'unrelated')
      h.git(dir, 'checkout', '-q', '--orphan', 'main')
      h.git(dir, 'rm', '-rqf', '.')
      h.write(dir, 'a.txt', 'one\n')
      h.git(dir, 'add', '.')
      h.git(dir, 'commit', '-qm', 'base')
      local base = h.git(dir, 'rev-parse', 'HEAD')
      h.git(dir, 'checkout', '-qb', 'feature')
      h.write(dir, 'a.txt', 'ONE\n')
      vim.cmd.cd(dir)
      vim.cmd('Phab local')
      h.eq({ base = base, files = { { status = 'M', path = 'a.txt' } } }, { base = state.base, files = state.files })
    end,
  },
  {
    'limits the review to uncommitted changes when given HEAD',
    function()
      h.feature_repo()
      vim.cmd('Phab local HEAD')
      h.eq({ { status = 'M', path = 'a.txt' }, { status = 'A', path = 'new.txt' } }, state.files)
    end,
  },
  {
    'keeps the open review when the ref does not exist',
    function()
      h.feature_repo()
      vim.cmd('Phab local HEAD')
      vim.cmd('Phab local no-such-branch')
      h.eq('HEAD', state.model.ref)
      h.eq({ { msg = '[phorge-review] unknown ref "no-such-branch"', level = vim.log.levels.ERROR } }, h.notifications)
    end,
  },
  {
    'copies drafts with their code and the overall message to the clipboard',
    function()
      h.feature_repo()
      local copied = stub_clipboard()
      vim.cmd('Phab local')
      local base = state.base:sub(1, 10)
      comment('a.txt', 2, 3, 'Why uppercase?')
      comment('new.txt', 1, 1, 'Is this file needed?')
      vim.cmd('Phab submit')
      h.submit_editor({ 'Overall looks good.' })
      h.eq({
        ['+'] = table.concat({
          ('Review comments on the changes against %s (`git diff %s`). Address each one; line numbers refer to the files as they were when I commented.'):format(
            base,
            base
          ),
          '',
          'Overall looks good.',
          '',
          '## a.txt:2-3',
          '',
          '```',
          'TWO',
          'THREE',
          '```',
          '',
          'Why uppercase?',
          '',
          '## new.txt:1',
          '',
          '```',
          'fresh',
          '```',
          '',
          'Is this file needed?',
          '',
        }, '\n'),
      }, copied)
      h.eq({}, state.drafts)
    end,
  },
  {
    'keeps the drafts when the clipboard is unavailable',
    function()
      h.feature_repo()
      h.stub(vim.fn, 'setreg', function()
        error('clipboard: No provider')
      end)
      vim.cmd('Phab local')
      comment('a.txt', 2, 2, 'Why uppercase?')
      vim.cmd('Phab submit')
      h.submit_editor({ '' })
      h.eq({
        {
          path = 'a.txt',
          line = 2,
          length = 1,
          code = { 'TWO' },
          comments = { { author = 'you', text = 'Why uppercase?' } },
        },
      }, h.drafts('a.txt'))
      h.eq(vim.log.levels.ERROR, h.notifications[#h.notifications].level)
    end,
  },
  {
    'restores the drafts of a branch when the review is reopened',
    function()
      h.feature_repo()
      vim.cmd('Phab local')
      comment('a.txt', 2, 2, 'Why uppercase?')
      vim.cmd('Phab close')
      vim.cmd('Phab local')
      h.eq({
        {
          path = 'a.txt',
          line = 2,
          length = 1,
          code = { 'TWO' },
          comments = { { author = 'you', text = 'Why uppercase?' } },
        },
      }, h.drafts('a.txt'))
    end,
  },
  {
    'opens the comment editor without a hard text width',
    function()
      h.feature_repo()
      -- Mimics a user ftplugin that hard-wraps markdown.
      vim.api.nvim_create_autocmd('FileType', {
        group = vim.api.nvim_create_augroup(h.augroup, {}),
        pattern = 'markdown',
        command = 'setlocal textwidth=100',
      })
      vim.cmd('Phab local')
      ui.open_file(state.file_set['a.txt'])
      comments.new_comment(1, 1)
      h.eq({ 'markdown', 0 }, { vim.bo.filetype, vim.bo.textwidth })
    end,
  },
  {
    'reopens a deleted file without a buffer name clash',
    function()
      h.feature_repo()
      vim.cmd('Phab local')
      ui.open_file(state.file_set['d.txt'])
      ui.open_file(state.file_set['d.txt'])
      h.eq(
        { name = 'phorge-review://base/d.txt', lines = { 'gone' } },
        { name = vim.api.nvim_buf_get_name(0), lines = vim.api.nvim_buf_get_lines(0, 0, -1, false) }
      )
    end,
  },
  {
    'puts the cursor on a change in the first line of the file',
    function()
      local dir = h.feature_repo()
      h.write(dir, 'a.txt', 'ONE\ntwo\nthree\nFOUR\n')
      vim.cmd('Phab local')
      ui.open_file(state.file_set['a.txt'])
      h.eq(1, vim.api.nvim_win_get_cursor(0)[1])
    end,
  },
  {
    'drops the diff split when its window is used to edit another file',
    function()
      h.feature_repo()
      vim.cmd('Phab local')
      ui.open_file(state.file_set['a.txt'])
      vim.cmd.edit('new.txt')
      h.eq({ diff = false, windows = 2 }, { diff = vim.wo.diff, windows = #vim.api.nvim_tabpage_list_wins(0) })
    end,
  },
  {
    'renders the comments of a file once when opening it',
    function()
      h.feature_repo()
      require('phorge-review').setup({ diff_split = false })
      vim.cmd('Phab local')
      local refreshed = {}
      local refresh_buf = comments.refresh_buf
      h.stub(comments, 'refresh_buf', function(buf)
        table.insert(refreshed, buf)
        refresh_buf(buf)
      end)
      ui.open_file(state.file_set['a.txt'])
      local buf = vim.api.nvim_get_current_buf()
      h.eq(
        { buf },
        vim.tbl_filter(function(b)
          return b == buf
        end, refreshed)
      )
    end,
  },
  {
    'marks every line of an untracked file as added when not using a diff split',
    function()
      h.feature_repo()
      require('phorge-review').setup({ diff_split = false })
      vim.cmd('Phab local')
      ui.open_file(state.file_set['new.txt'])
      local ns = vim.api.nvim_get_namespaces()['phorge-review.changes']
      local rows = vim.tbl_map(function(m)
        return m[2]
      end, vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}))
      h.eq({ 0, 1 }, rows)
    end,
  },
  {
    'steps through the files in panel order and wraps around',
    function()
      h.feature_repo()
      vim.cmd('Phab local')
      ui.open_file(state.file_set['a.txt'])
      ui.step_file(1)
      h.eq('c.txt', state.current_file)
      ui.step_file(-1)
      ui.step_file(-1)
      h.eq('new.txt', state.current_file)
      ui.step_file(1)
      h.eq('a.txt', state.current_file)
    end,
  },
  {
    'continues the comment keys in the next file with comments and wraps around',
    function()
      h.feature_repo()
      vim.cmd('Phab local')
      comment('a.txt', 2, 2, 'first')
      comment('c.txt', 1, 1, 'second')
      ui.open_file(state.file_set['a.txt'])
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local function key(lhs)
        vim.cmd('normal ' .. lhs)
        return { state.current_file, vim.api.nvim_win_get_cursor(0)[1] }
      end
      h.eq({ 'a.txt', 2 }, key(']r'))
      h.eq({ 'c.txt', 1 }, key(']r'))
      h.eq({ 'a.txt', 2 }, key(']r'))
      h.eq({ 'c.txt', 1 }, key('[r'))
      h.eq({ 'a.txt', 2 }, key('[r'))
    end,
  },
  {
    'continues the hunk keys in the next changed file and wraps around',
    function()
      h.feature_repo()
      vim.cmd('Phab local')
      ui.open_file(state.file_set['a.txt'])
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local function key(lhs)
        vim.cmd('normal ' .. lhs)
        return { state.current_file, vim.api.nvim_win_get_cursor(0)[1] }
      end
      h.eq({ 'a.txt', 2 }, key(']c'))
      h.eq({ 'c.txt', 1 }, key(']c'))
      h.eq({ 'd.txt', 1 }, key(']c'))
      h.eq({ 'new.txt', 1 }, key(']c'))
      h.eq({ 'a.txt', 2 }, key(']c'))
      h.eq({ 'new.txt', 1 }, key('[c'))
      h.eq({ 'd.txt', 1 }, key('[c'))
    end,
  },
  {
    'binds the file keys only in review buffers until the review closes',
    function()
      local function has_key(buf, lhs)
        return vim.api.nvim_buf_call(buf, function()
          return vim.fn.maparg(lhs, 'n') ~= ''
        end)
      end
      h.feature_repo()
      vim.cmd('Phab local')
      ui.open_file(state.file_set['a.txt'])
      local first = vim.api.nvim_get_current_buf()
      h.eq({ true, true }, { has_key(first, ']f'), has_key(first, ']r') })
      ui.open_file(state.file_set['c.txt'])
      h.eq({ false, false }, { has_key(first, ']f'), has_key(first, ']r') })
      local other = vim.api.nvim_create_buf(true, false)
      h.eq(
        '',
        vim.api.nvim_buf_call(other, function()
          return vim.fn.maparg('[f', 'n')
        end)
      )
      vim.cmd('Phab close')
      h.eq(
        '',
        vim.api.nvim_buf_call(vim.fn.bufnr('c.txt'), function()
          return vim.fn.maparg(']f', 'n')
        end)
      )
    end,
  },
}
