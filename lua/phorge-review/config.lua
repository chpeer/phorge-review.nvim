local M = {}

M.defaults = {
  -- Phabricator base URI, e.g. "https://phabricator.example.com/". Defaults to
  -- `phabricator.uri` from the nearest `.arcconfig`.
  uri = nil,
  -- Conduit API token. Defaults to $PHORGE_REVIEW_TOKEN, then the matching host
  -- entry in `arcrc`.
  token = nil,
  arcrc = '~/.arcrc',

  panel = {
    width = 44,
    -- Show changed files as a directory tree (single-child directories are
    -- merged); false lists full paths.
    tree = true,
  },
  -- Open the base revision of a file in a vertical split in diff mode. When
  -- false, changed lines are highlighted in the file buffer instead.
  diff_split = true,
  -- Fold unchanged regions in the diff split (Neovim's default diff behaviour).
  diff_folds = true,
  -- Maximum display width of rendered inline comments.
  comment_width = 90,
  comment_border = '┃ ',
  signs = {
    comment = '●',
    draft = '○',
    added = '▎',
    changed = '▎',
    deleted = '▁',
  },
  -- How many timeline entries to show in the panel.
  panel_timeline = 8,
  -- Keymaps bound to the <Plug>(phorge-review-*) mappings. Set a key to false
  -- to skip it, or `keymaps = false` to define none. `next_file`, `prev_file`,
  -- `next` and `prev` are buffer-local to the panel and the open review files,
  -- `next_hunk` and `prev_hunk` to the open review files; the others are global.
  keymaps = {
    next_file = ']f',
    prev_file = '[f',
    comment = '<leader>rc',
    submit = '<leader>rs',
    files = '<leader>rf',
    toggle_comments = '<leader>rt',
    browse = '<leader>rb',
    next = ']r',
    prev = '[r',
    next_hunk = ']c',
    prev_hunk = '[c',
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
end

return M
