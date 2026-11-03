-- Shared test helpers: assertions, scratch git repositories, stubs and a reset
-- between tests.
local M = {}

-- Notifications sent by the plugin, as `{ msg, level }`. Captured instead of
-- printed so that ERROR notifications do not abort headless runs.
M.notifications = {}
vim.notify = function(msg, level)
  table.insert(M.notifications, { msg = msg, level = level })
end

-- Autocommand group for test-only autocommands; cleared by `reset()`.
M.augroup = 'phorge-review-test'

local stubs = {}

--- Fails with both values printed unless they are deeply equal.
function M.eq(expected, actual, what)
  if not vim.deep_equal(expected, actual) then
    error(
      ('%s\n  expected: %s\n  actual:   %s'):format(what or 'values differ', vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

--- Replaces `tbl[key]` with `value` until the end of the test.
function M.stub(tbl, key, value)
  local original = tbl[key]
  tbl[key] = value
  table.insert(stubs, function()
    tbl[key] = original
  end)
end

--- Processes events until `predicate` returns true, failing after `timeout` ms.
function M.wait(predicate, what, timeout)
  if not vim.wait(timeout or 2000, predicate, 10) then
    error('timed out waiting for ' .. (what or 'condition'), 2)
  end
end

function M.git(dir, ...)
  local r = vim.system({ 'git', '-C', dir, ... }, { text = true }):wait()
  assert(r.code == 0, r.stderr)
  return vim.trim(r.stdout)
end

function M.write(dir, path, text)
  vim.fn.mkdir(vim.fs.dirname(vim.fs.joinpath(dir, path)), 'p')
  local f = assert(io.open(vim.fs.joinpath(dir, path), 'w'))
  f:write(text)
  f:close()
end

--- Creates an empty repository on `master` and returns its path.
function M.repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  M.git(dir, 'init', '-q', '-b', 'master')
  M.git(dir, 'config', 'user.email', 'test@example.com')
  M.git(dir, 'config', 'user.name', 'test')
  return vim.fn.resolve(dir)
end

--- A repository on branch `feature`, branched from `master`, with every kind
--- of change: a committed and further uncommitted modification (`a.txt`), a
--- rename (`b.txt` -> `c.txt`), a deletion (`d.txt`) and an untracked file
--- (`new.txt`). Makes it the current directory.
function M.feature_repo()
  local dir = M.repo()
  M.write(dir, 'a.txt', 'one\ntwo\nthree\nfour\n')
  M.write(dir, 'b.txt', 'keep\nme\n')
  M.write(dir, 'd.txt', 'gone\n')
  M.git(dir, 'add', '.')
  M.git(dir, 'commit', '-qm', 'base')
  M.git(dir, 'checkout', '-qb', 'feature')
  M.write(dir, 'a.txt', 'one\nTWO\nthree\nfour\n')
  M.git(dir, 'mv', 'b.txt', 'c.txt')
  M.git(dir, 'rm', '-q', 'd.txt')
  M.git(dir, 'commit', '-qm', 'feature')
  M.write(dir, 'a.txt', 'one\nTWO\nTHREE\nfour\n')
  M.write(dir, 'new.txt', 'fresh\nfile\n')
  vim.cmd.cd(dir)
  return dir
end

--- Replaces the contents of the focused comment/submit editor and saves it.
function M.submit_editor(lines)
  vim.cmd.stopinsert()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.cmd.write()
end

--- Drafts of `path` without their creation date, for comparison.
function M.drafts(path)
  return vim.tbl_map(function(d)
    d = vim.deepcopy(d)
    d.comments[1].date = nil
    return d
  end, require('phorge-review.state').drafts[path] or {})
end

function M.reset()
  for i = #stubs, 1, -1 do
    stubs[i]()
  end
  stubs = {}
  pcall(vim.api.nvim_del_augroup_by_name, M.augroup)
  pcall(require('phorge-review').close)
  require('phorge-review').setup()
  vim.cmd('silent! tabonly!')
  vim.cmd('silent! only!')
  vim.cmd('silent! %bwipeout!')
  for k in pairs(M.notifications) do
    M.notifications[k] = nil
  end
end

return M
