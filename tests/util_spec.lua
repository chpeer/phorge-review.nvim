local h = require('helpers')
local ui = require('phorge-review.ui')
local util = require('phorge-review.util')

--- The file tree reduced to names and file paths.
local function shape(node)
  return {
    name = node.name,
    files = vim.tbl_map(function(f)
      return f.path
    end, node.files),
    dirs = vim.tbl_map(shape, node.dirs),
  }
end

return {
  {
    'wraps text at word boundaries and keeps paragraph breaks',
    function()
      h.eq({ 'one two', 'three', '', 'four' }, util.wrap('one two three\n\nfour', 8))
    end,
  },
  {
    'shortens the first non-empty line to the given width',
    function()
      h.eq('first l…', util.one_line('\nfirst line\nsecond', 8))
    end,
  },
  {
    'drops the leading whitespace of the first line',
    function()
      h.eq('- Comments', util.one_line('  \n   - Comments\n  - more', 40))
    end,
  },
  {
    'merges single-child directories in the file tree',
    function()
      local tree = ui.file_tree({
        { status = 'M', path = 'a/b/c/one.lua' },
        { status = 'M', path = 'a/b/c/two.lua' },
        { status = 'A', path = 'a/x.lua' },
        { status = 'M', path = 'top.lua' },
      })
      h.eq({
        name = '',
        files = { 'top.lua' },
        dirs = {
          {
            name = 'a',
            files = { 'a/x.lua' },
            dirs = { { name = 'b/c', files = { 'a/b/c/one.lua', 'a/b/c/two.lua' }, dirs = {} } },
          },
        },
      }, shape(tree))
    end,
  },
  {
    'shows the current user as "you"',
    function()
      local user = vim.env.USER
      vim.env.USER = 'alice'
      local ok, err = pcall(function()
        h.eq(
          { 'you', 'bob', 'you' },
          { util.display_author('alice'), util.display_author('bob'), util.display_author('you') == 'you' and 'you' }
        )
      end)
      vim.env.USER = user
      assert(ok, err)
    end,
  },
}
