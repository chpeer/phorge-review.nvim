local async = require('phorge-review.async')
local comments = require('phorge-review.comments')
local config = require('phorge-review.config')
local conduit = require('phorge-review.conduit')
local git = require('phorge-review.git')
local review = require('phorge-review.review')
local state = require('phorge-review.state')
local ui = require('phorge-review.ui')
local util = require('phorge-review.util')

local M = {}

local applied_keymaps = {}

--- Binds the configured global keys to the <Plug>(phorge-review-*) mappings.
function M.apply_keymaps()
  for _, m in ipairs(applied_keymaps) do
    pcall(vim.keymap.del, m.mode, m.lhs)
  end
  applied_keymaps = {}
  local keymaps = config.options.keymaps
  if not keymaps then
    return
  end
  for name, lhs in pairs(keymaps) do
    if lhs and not ui.BUFFER_KEYMAPS[name] then
      local mode = name == 'comment' and { 'n', 'x' } or 'n'
      local plug = ('<Plug>(phorge-review-%s)'):format(name:gsub('_', '-'))
      vim.keymap.set(mode, lhs, plug, { desc = 'phorge-review: ' .. name:gsub('_', ' ') })
      applied_keymaps[#applied_keymaps + 1] = { mode = mode, lhs = lhs }
    end
  end
end

function M.setup(opts)
  config.setup(opts)
  conduit.reset()
  M.apply_keymaps()
end

--- Accepts "D123", "123" or a revision URL.
local function parse_id(arg)
  if not arg or arg == '' then
    return nil
  end
  return tonumber(arg:match('D(%d+)/?%s*$') or arg:match('^(%d+)$'))
end

local function resolve_base(root, model)
  if model.base and git.commit_exists(root, model.base) then
    return model.base
  end
  local refs = { 'origin/HEAD', 'origin/master', 'origin/main', 'master', 'main' }
  if model.onto then
    table.insert(refs, 1, model.onto)
  end
  for _, ref in ipairs(refs) do
    -- A ref without common history has no merge base; try the next one.
    local base = git.ref_exists(root, ref) and git.merge_base(root, ref)
    if base then
      return base
    end
  end
end

-- Incremented by every open/refresh/close so that a fetch finishing after a
-- newer action is discarded instead of clobbering the current review.
local generation = 0

--- Makes `model` the current review and opens or re-renders the panel. A
--- review open for a different revision (or local vs. revision) is closed.
local function activate(root, model, base)
  if state.active() and (state.model.id ~= model.id or state.model.is_local ~= model.is_local) then
    ui.close()
  end
  local reopen = not state.active()
  if reopen then
    state.reset()
  end
  state.root, state.model, state.base = root, model, base
  state.files = model.files
  state.file_set = {}
  for _, f in ipairs(state.files) do
    state.file_set[f.path] = f
  end
  state.drafts = comments.load_drafts()
  comments.reconcile_drafts()
  if reopen then
    ui.open_panel()
  else
    ui.render_panel()
  end
  comments.refresh_all()
end

local function load(id, root)
  generation = generation + 1
  local my_generation = generation
  async.run(function()
    local err, model = review.fetch(id)
    if generation ~= my_generation then
      return
    end
    if err then
      return util.notify(err, vim.log.levels.ERROR)
    end
    local base = resolve_base(root, model)
    if not base then
      return util.notify('could not determine a base commit for D' .. id, vim.log.levels.ERROR)
    end
    local paths = vim.tbl_map(function(f)
      return f.path
    end, model.files)
    if #paths > 0 and not git.has_changes(root, base, paths) then
      util.notify(
        ("working tree has no changes to D%d's files against %s; check out the revision or run `:Phab patch D%d`"):format(
          id,
          base:sub(1, 10),
          id
        ),
        vim.log.levels.WARN
      )
    end
    activate(root, model, base)
  end)
end

--- Builds a local review of the working tree against the merge base of HEAD
--- with `ref` (default: the default branch). No Conduit involved.
local function load_local(ref, root)
  generation = generation + 1
  local base
  if ref then
    if not git.ref_exists(root, ref) then
      return util.notify('unknown ref "' .. ref .. '"', vim.log.levels.ERROR)
    end
    base = git.merge_base(root, ref)
  else
    base = resolve_base(root, {})
  end
  if not base then
    return util.notify('could not determine a base commit', vim.log.levels.ERROR)
  end
  local files = git.changed_files(root, base)
  if #files == 0 then
    util.notify(('no changes against %s'):format(base:sub(1, 10)), vim.log.levels.WARN)
  end
  activate(root, {
    is_local = true,
    ref = ref,
    title = git.current_branch(root) or 'HEAD',
    files = files,
    inlines = {},
    timeline = {},
    reviewers = {},
  }, base)
end

--- Opens a local review of the working tree against the branch base, or the
--- merge base with `ref` when given.
function M.open_local(ref)
  local root = git.root(vim.fn.getcwd())
  if not root then
    return util.notify('not inside a git repository', vim.log.levels.ERROR)
  end
  load_local(ref ~= '' and ref or nil, root)
end

--- Opens the review for `arg` (revision ID/URL) or the revision referenced by HEAD.
function M.open(arg)
  local root = git.root(vim.fn.getcwd())
  if not root then
    return util.notify('not inside a git repository', vim.log.levels.ERROR)
  end
  local id = parse_id(arg)
  if arg and arg ~= '' and not id then
    return util.notify('cannot parse revision from "' .. arg .. '"', vim.log.levels.ERROR)
  end
  id = id or git.branch_revision(root)
  if not id then
    return util.notify(
      'no revision given and no commit of the branch has a "Differential Revision:" trailer',
      vim.log.levels.ERROR
    )
  end
  util.notify(('fetching D%d…'):format(id))
  load(id, root)
end

function M.refresh()
  if not state.active() then
    return util.notify('no review open', vim.log.levels.WARN)
  end
  if state.model.is_local then
    load_local(state.model.ref, state.root)
  else
    load(state.model.id, state.root)
  end
end

function M.close()
  generation = generation + 1
  ui.close()
end

--- Runs `arc patch D<id>` in a terminal split and opens the review on success.
function M.patch(arg)
  local id = parse_id(arg)
  if not id then
    return util.notify('usage: :Phab patch D123', vim.log.levels.ERROR)
  end
  local root = git.root(vim.fn.getcwd())
  if not root then
    return util.notify('not inside a git repository', vim.log.levels.ERROR)
  end
  vim.cmd('botright 15new')
  vim.bo.bufhidden = 'wipe'
  local cmd = { 'arc', 'patch', 'D' .. id }
  local opts = {
    cwd = root,
    on_exit = function(_, code)
      if code == 0 then
        vim.schedule(function()
          M.open('D' .. id)
        end)
      end
    end,
  }
  if vim.fn.has('nvim-0.11') == 1 then
    opts.term = true
    vim.fn.jobstart(cmd, opts)
  else
    vim.fn.termopen(cmd, opts)
  end
end

local subcommands = {
  open = function(arg)
    M.open(arg)
  end,
  ['local'] = M.open_local,
  close = M.close,
  refresh = M.refresh,
  patch = M.patch,
  comment = function(_, o)
    comments.new_comment(o.line1, o.line2)
  end,
  submit = comments.submit,
  ['toggle-comments'] = comments.toggle_comments,
  description = ui.description,
  files = ui.open_panel,
  ['next-file'] = function()
    ui.step_file(1)
  end,
  ['prev-file'] = function()
    ui.step_file(-1)
  end,
  browse = comments.browse,
  help = ui.help,
  next = function()
    comments.jump(1)
  end,
  prev = function()
    comments.jump(-1)
  end,
}

function M.command(o)
  local sub, rest = o.fargs[1], o.fargs[2]
  if sub == nil or parse_id(sub) then
    return M.open(sub)
  end
  local fn = subcommands[sub]
  if not fn then
    return util.notify('unknown subcommand "' .. sub .. '"', vim.log.levels.ERROR)
  end
  fn(rest, o)
end

function M.complete(lead, line)
  if line:match('^%S+%s+%S+%s') then
    return {}
  end
  return vim.tbl_filter(function(s)
    return s:sub(1, #lead) == lead
  end, vim.tbl_keys(subcommands))
end

return M
