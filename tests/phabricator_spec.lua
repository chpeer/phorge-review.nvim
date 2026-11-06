-- Phabricator mode against canned Conduit responses.
local h = require('helpers')
local comments = require('phorge-review.comments')
local state = require('phorge-review.state')
local ui = require('phorge-review.ui')

local REVISION = {
  id = 123,
  phid = 'PHID-DREV-1',
  fields = {
    title = 'Shout the second line',
    summary = 'Makes line two louder.',
    testPlan = '',
    status = { name = 'Needs Review', closed = false },
    authorPHID = 'PHID-USER-alice',
    diffPHID = 'PHID-DIFF-2',
    uri = 'https://phorge.example.com/D123',
  },
  attachments = {
    reviewers = { reviewers = { { reviewerPHID = 'PHID-USER-bob', status = 'accepted', isBlocking = false } } },
  },
}

-- transaction.search returns the newest transaction first.
local TRANSACTIONS = {
  { type = 'accept', authorPHID = 'PHID-USER-bob', dateCreated = 300 },
  {
    type = 'comment',
    authorPHID = 'PHID-USER-bob',
    dateCreated = 200,
    comments = { { id = 8, phid = 'PHID-XCMT-8', content = { raw = 'Looks fine.' }, dateCreated = 200 } },
  },
  {
    type = 'inline',
    authorPHID = 'PHID-USER-bob',
    dateCreated = 100,
    comments = { { id = 9, phid = 'PHID-XCMT-9', content = { raw = 'Nit: too loud.' }, dateCreated = 100 } },
    fields = { path = 'a.txt', line = 2, length = 1, diff = { id = 2 }, isDone = false },
  },
  { type = 'create', authorPHID = 'PHID-USER-alice', dateCreated = 50 },
}

--- A repository whose `feature` branch carries the revision, a stubbed
--- Conduit, and the review of D123 opened. `changes` overrides the changes
--- of its diff. Returns the recorded Conduit calls and the base commit.
local function open_revision(changes, raw_diff_of_base)
  local dir = h.repo()
  h.write(dir, 'a.txt', 'one\ntwo\nthree\n')
  h.git(dir, 'add', '.')
  h.git(dir, 'commit', '-qm', 'base')
  local base = h.git(dir, 'rev-parse', 'HEAD')
  h.git(dir, 'checkout', '-qb', 'feature')
  h.write(dir, 'a.txt', 'one\nTWO\nthree\n')
  h.git(dir, 'commit', '-qa', '-m', 'shout', '-m', 'Differential Revision: https://phorge.example.com/D123')
  local raw_diff
  if raw_diff_of_base then
    -- The revision is only available as its raw diff; the working tree is at the base.
    raw_diff = h.git(dir, 'diff', base, 'HEAD') .. '\n'
    h.git(dir, 'checkout', '-q', 'master')
  end
  vim.cmd.cd(dir)

  local responses = {
    ['differential.revision.search'] = { data = { REVISION } },
    ['differential.diff.search'] = {
      data = {
        {
          id = 2,
          phid = 'PHID-DIFF-2',
          fields = { refs = { { type = 'base', identifier = base }, { type = 'onto', name = 'master' } } },
        },
      },
    },
    ['transaction.search'] = { data = TRANSACTIONS },
    ['phid.query'] = { ['PHID-USER-alice'] = { name = 'alice' }, ['PHID-USER-bob'] = { name = 'bob' } },
    ['differential.querydiffs'] = { ['2'] = { changes = changes or { { type = 2, currentPath = 'a.txt' } } } },
    ['differential.createinline'] = { id = 55 },
    ['differential.createcomment'] = {},
    ['differential.getrawdiff'] = raw_diff,
  }
  local calls = {}
  h.stub(require('phorge-review.conduit'), 'call', function(method, params)
    return function(cb)
      table.insert(calls, { method = method, params = params })
      cb(nil, responses[method])
    end
  end)
  vim.cmd(raw_diff_of_base and 'Phab diff-only D123' or 'Phab D123')
  h.wait(state.active, 'the review to open')
  return calls, base
end

--- Holds back the reply to the next Conduit call. Returns a function that
--- sends `result` as the reply and waits until it has been handled.
local function hold_conduit()
  local pending
  h.stub(require('phorge-review.conduit'), 'call', function()
    return function(cb)
      pending = cb
    end
  end)
  return function(result)
    h.wait(function()
      return pending ~= nil
    end, 'a Conduit call')
    pending(nil, result)
    -- The reply resumes the coroutine in one scheduled callback; an error in
    -- it is reported in another.
    local handled = false
    vim.schedule(function()
      vim.schedule(function()
        handled = true
      end)
    end)
    h.wait(function()
      return handled
    end, 'the reply to be handled')
  end
end

--- Parameters of every recorded call to `method`.
local function params_of(calls, method)
  return vim.tbl_map(
    function(c)
      return c.params
    end,
    vim.tbl_filter(function(c)
      return c.method == method
    end, calls)
  )
end

return {
  {
    'shows a multi-line title on one line in the panel',
    function()
      h.stub(REVISION.fields, 'title', 'Shout the\nsecond line')
      open_revision()
      h.eq(
        { 'D123 · Needs Review · alice', 'Shout the second line' },
        vim.api.nvim_buf_get_lines(state.panel_buf, 0, 2, false)
      )
      ui.description()
      h.eq({ '# D123: Shout the second line' }, vim.api.nvim_buf_get_lines(0, 0, 1, false))
    end,
  },
  {
    'opens a revision with its files, reviewers, inline threads and timeline',
    function()
      local _, base = open_revision()
      h.eq({
        id = 123,
        phid = 'PHID-DREV-1',
        title = 'Shout the second line',
        summary = 'Makes line two louder.',
        test_plan = '',
        status = 'Needs Review',
        closed = false,
        author = 'alice',
        uri = 'https://phorge.example.com/D123',
        reviewers = { { name = 'bob', status = 'accepted', blocking = false } },
        diff_id = 2,
        diff_only = false,
        base = base,
        onto = 'master',
        files = { { status = 'M', path = 'a.txt' } },
        inlines = {
          ['a.txt'] = {
            {
              path = 'a.txt',
              line = 2,
              length = 1,
              diff_id = 2,
              comment_id = 9,
              done = false,
              comments = { { author = 'bob', text = 'Nit: too loud.', date = 100 } },
            },
          },
        },
        timeline = {
          { author = 'alice', date = 50, action = 'created the revision' },
          { author = 'bob', date = 200, text = 'Looks fine.' },
          { author = 'bob', date = 300, action = 'accepted' },
        },
      }, state.model)
      h.eq(base, state.base)
    end,
  },
  {
    'lists the source of a copy as modified and of a multi-copy as deleted',
    function()
      open_revision({
        { type = 5, currentPath = 'a.txt' },
        { type = 7, currentPath = 'b.txt', oldPath = 'a.txt' },
        { type = 8, currentPath = 'old.txt' },
        { type = 7, currentPath = 'x.txt', oldPath = 'old.txt' },
        { type = 7, currentPath = 'y.txt', oldPath = 'old.txt' },
      })
      h.eq({
        { status = 'M', path = 'a.txt' },
        { status = 'C', path = 'b.txt', old_path = 'a.txt' },
        { status = 'D', path = 'old.txt' },
        { status = 'C', path = 'x.txt', old_path = 'old.txt' },
        { status = 'C', path = 'y.txt', old_path = 'old.txt' },
      }, state.files)
    end,
  },
  {
    'saves an inline comment as a draft on the revision',
    function()
      local calls = open_revision()
      ui.open_file(state.file_set['a.txt'])
      comments.new_comment(2, 2)
      h.submit_editor({ 'Please lower it.' })
      h.wait(function()
        return state.draft_count() == 1
      end, 'the draft to be saved')
      h.eq({
        {
          revisionID = 123,
          filePath = 'a.txt',
          isNewFile = true,
          lineNumber = 2,
          lineLength = 0,
          content = 'Please lower it.',
        },
      }, params_of(calls, 'differential.createinline'))
      h.eq({
        {
          path = 'a.txt',
          line = 2,
          length = 1,
          id = 55,
          code = { 'TWO' },
          comments = { { author = 'you', text = 'Please lower it.' } },
        },
      }, h.drafts('a.txt'))
    end,
  },
  {
    'publishes the drafts with the chosen action and message',
    function()
      local calls = open_revision()
      ui.open_file(state.file_set['a.txt'])
      comments.new_comment(2, 2)
      h.submit_editor({ 'Please lower it.' })
      h.wait(function()
        return state.draft_count() == 1
      end, 'the draft to be saved')
      vim.cmd('Phab submit')
      h.submit_editor({ 'action: request-changes', '', 'One nit.' })
      h.wait(function()
        return state.draft_count() == 0
      end, 'the drafts to be published')
      h.eq(
        { { revision_id = 123, message = 'One nit.', action = 'reject', attach_inlines = true } },
        params_of(calls, 'differential.createcomment')
      )
    end,
  },
  {
    'ignores a draft reply that arrives after the review was closed',
    function()
      open_revision()
      ui.open_file(state.file_set['a.txt'])
      local reply = hold_conduit()
      comments.new_comment(2, 2)
      h.submit_editor({ 'Please lower it.' })
      vim.cmd('Phab close')
      local seen = #h.notifications
      reply({ id = 55 })
      h.eq(
        { drafts = {}, notifications = {} },
        { drafts = state.drafts, notifications = vim.list_slice(h.notifications, seen + 1) }
      )
    end,
  },
  {
    'shows the revision from its raw diff without touching the working tree',
    function()
      local _, base = open_revision(nil, true)
      local dir = vim.uv.cwd()
      ui.open_file(state.file_set['a.txt'])
      h.eq({ 'one', 'TWO', 'three' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      h.eq(true, vim.api.nvim_buf_get_name(0):match('^phorge%-review://revision/a%.txt$') ~= nil)
      -- The inline thread on line 2 is placed on the revision's version.
      local ns = vim.api.nvim_get_namespaces()['phorge-review.comments']
      local threads = vim.tbl_filter(function(m)
        return m[4].virt_lines ~= nil
      end, vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true }))
      h.eq(
        { 1 },
        vim.tbl_map(function(m)
          return m[2]
        end, threads)
      )
      comments.new_comment(2, 2)
      h.submit_editor({ 'Why uppercase?' })
      h.wait(function()
        return state.drafts['a.txt'] ~= nil
      end, 'the draft')
      h.eq({ head = base, status = '', disk = 'one\ntwo\nthree\n' }, {
        head = h.git(dir, 'rev-parse', 'HEAD'),
        status = h.git(dir, 'status', '--short'),
        disk = io.open(vim.fs.joinpath(dir, 'a.txt')):read('*a'),
      })
    end,
  },
  {
    'fetches the raw diff of a diff only once',
    function()
      local calls = open_revision(nil, true)
      local tree = state.tree
      vim.cmd('Phab close')
      vim.cmd('Phab diff-only D123')
      h.wait(state.active, 'the review to reopen')
      h.eq(1, #params_of(calls, 'differential.getrawdiff'))
      h.eq(tree, state.tree)
      h.eq({ diffID = 2 }, params_of(calls, 'differential.getrawdiff')[1])
    end,
  },
  {
    'does not ask about the diff only when the current branch is the revision',
    function()
      local asked = {}
      h.stub(vim.ui, 'select', function(items)
        table.insert(asked, items)
      end)
      open_revision()
      h.eq({}, asked)
      h.eq(nil, state.tree)
    end,
  },
  {
    'offers the diff only when the current branch is for another revision',
    function()
      open_revision(nil, true)
      vim.cmd('Phab close')
      h.stub(require('phorge-review.git'), 'branch_revision', function()
        return 200
      end)
      local asked
      h.stub(vim.ui, 'select', function(items, opts, on_choice)
        asked = { items = items, prompt = opts.prompt }
        on_choice(items[1])
      end)
      vim.cmd('Phab D123')
      h.wait(state.active, 'the review to open')
      h.eq({ 'Diff only (no checkout needed)', 'Working tree anyway' }, asked.items)
      h.eq('The current branch is for D200, not D123. Review:', asked.prompt)
      h.eq(true, state.tree ~= nil)
    end,
  },
  {
    'reviews the working tree when that is chosen over the diff only',
    function()
      open_revision(nil, true)
      vim.cmd('Phab close')
      h.stub(require('phorge-review.git'), 'branch_revision', function() end)
      h.stub(vim.ui, 'select', function(items, opts, on_choice)
        h.eq('The current branch is not for D123. Review:', opts.prompt)
        on_choice(items[2])
      end)
      vim.cmd('Phab D123')
      h.wait(state.active, 'the review to open')
      h.eq(nil, state.tree)
    end,
  },
  {
    'opens nothing when the prompt is dismissed',
    function()
      open_revision(nil, true)
      vim.cmd('Phab close')
      h.stub(require('phorge-review.git'), 'branch_revision', function() end)
      h.stub(vim.ui, 'select', function(_, _, on_choice)
        on_choice(nil)
      end)
      vim.cmd('Phab D123')
      h.eq(false, state.active())
    end,
  },
  {
    'opens the real file when the revision is in the working tree',
    function()
      open_revision()
      ui.open_file(state.file_set['a.txt'])
      h.eq(vim.fs.joinpath(vim.uv.cwd(), 'a.txt'), vim.api.nvim_buf_get_name(0))
    end,
  },
  {
    'keeps the drafts of a local review opened while a revision is being published',
    function()
      open_revision()
      local reply = hold_conduit()
      vim.cmd('Phab submit')
      h.submit_editor({ 'action: accept', '', 'Ship it.' })
      vim.cmd('Phab local')
      ui.open_file(state.file_set['a.txt'])
      comments.new_comment(2, 2)
      h.submit_editor({ 'Why uppercase?' })
      reply({})
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
    'closes the diff split for a working-tree file without the revision in diff-only mode',
    function()
      open_revision(nil, true)
      ui.open_file(state.file_set['a.txt'])
      vim.cmd.edit('a.txt')
      h.wait(function()
        return state.base_win == nil
      end, 'the diff split to close')
      h.eq(false, vim.wo.diff)
    end,
  },
}
