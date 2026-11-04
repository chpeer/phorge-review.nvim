local h = require('helpers')
local git = require('phorge-review.git')

return {
  {
    'lists modified, renamed, deleted and untracked files against the base',
    function()
      local dir = h.feature_repo()
      h.eq({
        { status = 'M', path = 'a.txt' },
        { status = 'R', path = 'c.txt', old_path = 'b.txt' },
        { status = 'D', path = 'd.txt' },
        { status = 'A', path = 'new.txt' },
      }, git.changed_files(dir, 'master'))
    end,
  },
  {
    'lists paths with non-ASCII characters, tabs and quotes verbatim',
    function()
      local dir = h.repo()
      h.write(dir, 'café.txt', 'one\n')
      h.write(dir, 'old "name".txt', 'keep\nme\n')
      h.git(dir, 'add', '.')
      h.git(dir, 'commit', '-qm', 'base')
      h.write(dir, 'café.txt', 'two\n')
      h.git(dir, 'mv', 'old "name".txt', 'new\tname.txt')
      h.write(dir, 'naïve.txt', 'fresh\n')
      h.eq({
        { status = 'M', path = 'café.txt' },
        { status = 'A', path = 'naïve.txt' },
        { status = 'R', path = 'new\tname.txt', old_path = 'old "name".txt' },
      }, git.changed_files(dir, 'HEAD'))
    end,
  },
  {
    'counts untracked files as changes',
    function()
      local dir = h.feature_repo()
      h.eq({ untracked = true, unchanged = false }, {
        untracked = git.has_changes(dir, 'HEAD', { 'new.txt' }),
        unchanged = git.has_changes(dir, 'HEAD', { 'c.txt' }),
      })
    end,
  },
  {
    'reports the checked-out branch',
    function()
      local dir = h.feature_repo()
      h.eq('feature', git.current_branch(dir))
    end,
  },
  {
    'returns zero-context hunks between the base and the working tree',
    function()
      local dir = h.feature_repo()
      h.eq({ { old_start = 2, old_count = 2, new_start = 2, new_count = 2 } }, git.hunks(dir, 'master', 'a.txt'))
    end,
  },
  {
    'returns hunks despite an external diff tool and forced colour',
    function()
      local dir = h.feature_repo()
      h.git(dir, 'config', 'diff.external', 'false')
      h.git(dir, 'config', 'color.diff', 'always')
      h.eq({ { old_start = 2, old_count = 2, new_start = 2, new_count = 2 } }, git.hunks(dir, 'master', 'a.txt'))
    end,
  },
  {
    'finds the merge base with another branch',
    function()
      local dir = h.feature_repo()
      h.eq(h.git(dir, 'rev-parse', 'master'), git.merge_base(dir, 'master'))
    end,
  },
}
