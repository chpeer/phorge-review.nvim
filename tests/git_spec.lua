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
    'finds the merge base with another branch',
    function()
      local dir = h.feature_repo()
      h.eq(h.git(dir, 'rev-parse', 'master'), git.merge_base(dir, 'master'))
    end,
  },
}
