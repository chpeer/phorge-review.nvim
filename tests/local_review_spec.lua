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
    'reopens the diff split when a jump returns to a changed file',
    function()
      h.feature_repo()
      vim.cmd('Phab local')
      ui.open_file(state.file_set['a.txt'])
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      vim.cmd.edit('new.txt')
      vim.cmd('normal! ' .. vim.keycode('<C-o>'))
      h.wait(function()
        return state.base_win and vim.api.nvim_win_is_valid(state.base_win)
      end, 'diff split')
      h.eq({
        file = 'a.txt',
        base = 'phorge-review://base/a.txt',
        cursor = 3,
        diff = true,
      }, {
        file = vim.fs.basename(vim.api.nvim_buf_get_name(0)),
        base = vim.api.nvim_buf_get_name(state.base_buf),
        cursor = vim.api.nvim_win_get_cursor(0)[1],
        diff = vim.wo.diff,
      })
    end,
  },
  {
    'opens the diff split of a changed file reached from another one',
    function()
      h.feature_repo()
      vim.cmd('Phab local')
      ui.open_file(state.file_set['a.txt'])
      vim.cmd.edit('c.txt')
      h.wait(function()
        return state.base_buf and vim.api.nvim_buf_get_name(state.base_buf):match('b%.txt$')
      end, 'diff split of c.txt')
      h.eq(3, #vim.api.nvim_tabpage_list_wins(0))
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
    'opens the review in its own tab and leaves the layout of the others alone',
    function()
      h.feature_repo()
      vim.cmd.edit('a.txt')
      vim.cmd('vsplit b.txt')
      local tab = vim.api.nvim_get_current_tabpage()
      local layout = vim.fn.winlayout()
      vim.cmd('Phab local')
      ui.open_file(state.file_set['c.txt'])
      h.eq(2, #vim.api.nvim_list_tabpages())
      h.eq(true, state.tabpage ~= tab)
      h.eq(layout, vim.fn.winlayout(vim.api.nvim_tabpage_get_number(tab)))
      vim.cmd('Phab close')
      h.eq({ tab }, vim.api.nvim_list_tabpages())
      h.eq(layout, vim.fn.winlayout())
    end,
  },
  {
    'opens the first file of the panel in the new tab with the panel cursor on it',
    function()
      h.feature_repo()
      vim.cmd('Phab local')
      h.eq(state.panel_win, vim.api.nvim_get_current_win())
      h.eq('a.txt', state.panel_items[vim.api.nvim_win_get_cursor(0)[1]].file.path)
      h.eq('a.txt', vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(state.main_win))))
      h.eq(true, vim.api.nvim_win_is_valid(state.base_win))
      vim.api.nvim_win_close(state.panel_win, true)
      ui.open_file(state.file_set['c.txt'])
      vim.cmd('Phab files')
      h.eq('c.txt', vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(state.main_win))))
    end,
  },
  {
    'closes the review when its tab is closed',
    function()
      h.feature_repo()
      vim.cmd('Phab local')
      local panel_buf = state.panel_buf
      vim.cmd('tabclose')
      h.eq({ false, false }, { state.active(), vim.api.nvim_buf_is_valid(panel_buf) })
    end,
  },
  {
    'closes the review when it is the only tab',
    function()
      h.feature_repo()
      vim.cmd('Phab local')
      vim.cmd('tabonly')
      vim.cmd('Phab close')
      h.eq({ false, 1 }, { state.active(), #vim.api.nvim_list_tabpages() })
    end,
  },
}
