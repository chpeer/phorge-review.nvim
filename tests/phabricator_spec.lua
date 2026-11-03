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
--- Conduit, and the review of D123 opened. Returns the recorded Conduit calls
--- and the base commit.
local function open_revision()
  local dir = h.repo()
  h.write(dir, 'a.txt', 'one\ntwo\nthree\n')
  h.git(dir, 'add', '.')
  h.git(dir, 'commit', '-qm', 'base')
  local base = h.git(dir, 'rev-parse', 'HEAD')
  h.git(dir, 'checkout', '-qb', 'feature')
  h.write(dir, 'a.txt', 'one\nTWO\nthree\n')
  h.git(dir, 'commit', '-qam', 'shout')
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
    ['differential.querydiffs'] = { ['2'] = { changes = { { type = 2, currentPath = 'a.txt' } } } },
    ['differential.createinline'] = { id = 55 },
    ['differential.createcomment'] = {},
  }
  local calls = {}
  h.stub(require('phorge-review.conduit'), 'call', function(method, params)
    return function(cb)
      table.insert(calls, { method = method, params = params })
      cb(nil, responses[method])
    end
  end)
  vim.cmd('Phab D123')
  h.wait(state.active, 'the review to open')
  return calls, base
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
}
