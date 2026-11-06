if vim.g.loaded_phorge_review then
  return
end
vim.g.loaded_phorge_review = true

if vim.fn.has('nvim-0.10') == 0 then
  vim.notify('[phorge-review] requires Neovim 0.10 or newer', vim.log.levels.ERROR)
  return
end

-- The plugin is loaded from a checkout, so no plugin manager runs :helptags for
-- it. Regenerate doc/tags when it is missing or older than the help file.
do
  local doc = vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))), 'doc')
  local src, tags =
    vim.uv.fs_stat(vim.fs.joinpath(doc, 'phorge-review.txt')), vim.uv.fs_stat(vim.fs.joinpath(doc, 'tags'))
  if src and (not tags or tags.mtime.sec < src.mtime.sec) then
    pcall(vim.cmd.helptags, vim.fn.fnameescape(doc))
  end
end

vim.api.nvim_create_user_command('Phab', function(o)
  require('phorge-review').command(o)
end, {
  nargs = '*',
  range = true,
  complete = function(lead, line)
    return require('phorge-review').complete(lead, line)
  end,
  desc = 'phorge-review: review a Phabricator revision',
})

vim.keymap.set(
  'n',
  '<Plug>(phorge-review-comment)',
  '<Cmd>Phab comment<CR>',
  { desc = 'phorge-review: comment on line' }
)
vim.keymap.set(
  'x',
  '<Plug>(phorge-review-comment)',
  ':Phab comment<CR>',
  { silent = true, desc = 'phorge-review: comment on selection' }
)
vim.keymap.set('n', '<Plug>(phorge-review-next)', '<Cmd>Phab next<CR>', { desc = 'phorge-review: next comment' })
vim.keymap.set('n', '<Plug>(phorge-review-prev)', '<Cmd>Phab prev<CR>', { desc = 'phorge-review: previous comment' })
vim.keymap.set(
  'n',
  '<Plug>(phorge-review-toggle-comments)',
  '<Cmd>Phab toggle-comments<CR>',
  { desc = 'phorge-review: toggle comments' }
)
vim.keymap.set('n', '<Plug>(phorge-review-submit)', '<Cmd>Phab submit<CR>', { desc = 'phorge-review: submit review' })
vim.keymap.set('n', '<Plug>(phorge-review-next-file)', '<Cmd>Phab next-file<CR>', { desc = 'phorge-review: next file' })
vim.keymap.set(
  'n',
  '<Plug>(phorge-review-prev-file)',
  '<Cmd>Phab prev-file<CR>',
  { desc = 'phorge-review: previous file' }
)
vim.keymap.set('n', '<Plug>(phorge-review-files)', '<Cmd>Phab files<CR>', { desc = 'phorge-review: focus panel' })
vim.keymap.set('n', '<Plug>(phorge-review-browse)', '<Cmd>Phab browse<CR>', { desc = 'phorge-review: open in browser' })
require('phorge-review').apply_keymaps()

local function set_highlights()
  local links = {
    PhorgeReviewBorder = 'Comment',
    PhorgeReviewAuthor = 'Title',
    PhorgeReviewMeta = 'Comment',
    PhorgeReviewComment = 'Normal',
    PhorgeReviewDraft = 'DiagnosticWarn',
    PhorgeReviewDone = 'DiagnosticOk',
    PhorgeReviewStale = 'DiagnosticHint',
    PhorgeReviewSign = 'DiagnosticInfo',
    PhorgeReviewRange = 'ColorColumn',
    PhorgeReviewAdded = 'DiffAdd',
    PhorgeReviewAddedLine = 'DiffAdd',
    PhorgeReviewChanged = 'DiffChange',
    PhorgeReviewChangedLine = 'DiffChange',
    PhorgeReviewDeleted = 'DiffDelete',
    PhorgeReviewTitle = 'Title',
    PhorgeReviewSection = 'Special',
    PhorgeReviewDir = 'Directory',
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end
set_highlights()

local group = vim.api.nvim_create_augroup('phorge-review', { clear = true })
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_highlights })
vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufReadPost' }, {
  group = group,
  callback = function(ev)
    if
      package.loaded['phorge-review.state']
      and require('phorge-review.state').active()
      and not require('phorge-review.ui').opening
    then
      require('phorge-review.comments').refresh_buf(ev.buf)
    end
  end,
})
