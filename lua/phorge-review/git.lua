local M = {}

local function git(root, args, opts)
  local cmd = { 'git' }
  if root then
    vim.list_extend(cmd, { '-C', root })
  end
  vim.list_extend(cmd, args)
  local r = vim.system(cmd, { text = true }):wait()
  if r.code ~= 0 then
    return nil, vim.trim(r.stderr or '')
  end
  if opts and opts.raw then
    return r.stdout
  end
  return vim.trim(r.stdout or '')
end

function M.root(dir)
  return (git(dir, { 'rev-parse', '--show-toplevel' }))
end

function M.commit_exists(root, sha)
  return git(root, { 'cat-file', '-e', sha .. '^{commit}' }) ~= nil
end

function M.ref_exists(root, ref)
  return git(root, { 'rev-parse', '--verify', '--quiet', ref }) ~= nil
end

function M.merge_base(root, ref)
  return (git(root, { 'merge-base', ref, 'HEAD' }))
end

--- Revision ID from the `Differential Revision:` trailer of HEAD, if any.
function M.revision_from_head(root)
  local body = git(root, { 'log', '-1', '--format=%B' }) or ''
  return tonumber(body:match('Differential Revision:%s*%S-/D(%d+)'))
end

function M.current_branch(root)
  return (git(root, { 'rev-parse', '--abbrev-ref', 'HEAD' }))
end

local NAME_STATUS = { A = 'A', M = 'M', T = 'M', D = 'D', R = 'R', C = 'C' }

--- Files that differ between `base` and the working tree, including untracked
--- files, as `{ status, path, old_path }` sorted by path.
function M.changed_files(root, base)
  local files = {}
  for line in vim.gsplit(git(root, { 'diff', '--name-status', '-M', base }) or '', '\n', { trimempty = true }) do
    local parts = vim.split(line, '\t', { plain = true })
    local status = NAME_STATUS[parts[1]:sub(1, 1)]
    if status == 'R' or status == 'C' then
      files[#files + 1] = { status = status, path = parts[3], old_path = parts[2] }
    elseif status then
      files[#files + 1] = { status = status, path = parts[2] }
    end
  end
  for path in vim.gsplit(git(root, { 'ls-files', '--others', '--exclude-standard' }) or '', '\n', { trimempty = true }) do
    files[#files + 1] = { status = 'A', path = path }
  end
  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

--- Whether any of `paths` differs between `base` and the working tree.
function M.has_changes(root, base, paths)
  local args = { 'diff', '--name-only', base, '--' }
  vim.list_extend(args, paths)
  return (git(root, args) or '') ~= ''
end

--- Contents of `path` at `rev`, or nil if it does not exist there.
function M.show(root, rev, path)
  return (git(root, { 'show', rev .. ':' .. path }, { raw = true }))
end

--- Hunks of `path` between `base` and the working tree.
function M.hunks(root, base, path)
  local out = git(root, { 'diff', '-U0', base, '--', path }) or ''
  local hunks = {}
  for os_, oc, ns_, nc in ('\n' .. out):gmatch('\n@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@') do
    hunks[#hunks + 1] = {
      old_start = tonumber(os_),
      old_count = oc == '' and 1 or tonumber(oc),
      new_start = tonumber(ns_),
      new_count = nc == '' and 1 or tonumber(nc),
    }
  end
  return hunks
end

return M
