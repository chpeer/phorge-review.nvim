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
}
