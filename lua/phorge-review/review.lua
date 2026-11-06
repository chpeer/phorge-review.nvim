-- Fetches a revision from Conduit and normalises it into a plain model:
--
--   {
--     id, phid, title, summary, test_plan, status, closed, author, uri,
--     reviewers = { { name, status, blocking } },
--     diff_id, base, onto,
--     raw_diff,                            -- unified diff of the active diff, if requested
--     files = { { status, path, old_path } },
--     inlines = { [path] = { thread } },   -- sorted by line
--     timeline = { { author, date, text | action } },
--   }
--
--   thread = { path, line, length, diff_id, done, comments = { { author, text, date } } }
local async = require('phorge-review.async')
local conduit = require('phorge-review.conduit')

local M = {}

local ACTION_LABEL = {
  create = 'created the revision',
  update = 'updated the diff',
  accept = 'accepted',
  ['request-changes'] = 'requested changes',
  ['plan-changes'] = 'planned changes',
  ['request-review'] = 'requested review',
  resign = 'resigned',
  abandon = 'abandoned',
  reclaim = 'reclaimed',
  commandeer = 'commandeered',
  close = 'closed',
}

-- DifferentialChangeType constants as reported by differential.querydiffs.
local CHANGE_STATUS = {
  [1] = 'A', -- add
  [2] = 'M', -- change
  [3] = 'D', -- delete
  [4] = 'D', -- move away (old path of a rename)
  [5] = 'M', -- copy away (source of a copy; still exists and may be edited)
  [6] = 'R', -- move here
  [7] = 'C', -- copy here
  [8] = 'D', -- multicopy (source moved to several places; no longer exists)
}

local function latest_comment(t)
  local c = t.comments and t.comments[#t.comments]
  if not c then
    return nil
  end
  return {
    id = c.id,
    phid = c.phid,
    text = c.removed and '(removed)' or (c.content and c.content.raw or ''),
    date = c.dateCreated or t.dateCreated,
  }
end

--- Must run inside `async.run`. Includes `raw_diff` when `load_raw_diff` is
--- given: a function from a diff ID to `err, raw_diff`. Returns `err, model`.
function M.fetch(id, load_raw_diff)
  local err, res = async.await(conduit.call('differential.revision.search', {
    constraints = { ids = { id } },
    attachments = { reviewers = true },
  }))
  if err then
    return err
  end
  local rev = res.data and res.data[1]
  if not rev then
    return ('D%d not found'):format(id)
  end

  local diffs
  err, diffs = conduit.search_all('differential.diff.search', { constraints = { revisionPHIDs = { rev.phid } } })
  if err then
    return err
  end
  local xacts
  err, xacts = conduit.search_all('transaction.search', { objectIdentifier = rev.phid })
  if err then
    return err
  end

  local reviewers_raw = rev.attachments and rev.attachments.reviewers and rev.attachments.reviewers.reviewers or {}
  local phids = {}
  local function want(p)
    if p then
      phids[p] = true
    end
  end
  want(rev.fields.authorPHID)
  for _, r in ipairs(reviewers_raw) do
    want(r.reviewerPHID)
  end
  for _, t in ipairs(xacts) do
    want(t.authorPHID)
  end
  local names = {}
  if next(phids) then
    err, names = async.await(conduit.call('phid.query', { phids = vim.tbl_keys(phids) }))
    if err then
      return err
    end
  end
  local function name(p)
    local n = names[p]
    return n and n.name or p or '?'
  end

  local active, onto = diffs[1], nil
  for _, d in ipairs(diffs) do
    if d.phid == rev.fields.diffPHID then
      active = d
    end
    for _, ref in ipairs(d.fields.refs or {}) do
      if ref.type == 'onto' and not onto then
        onto = ref.name
      end
    end
  end
  local base
  for _, ref in ipairs(active and active.fields.refs or {}) do
    if ref.type == 'base' then
      base = ref.identifier
    end
  end

  local files, raw_diff = {}, nil
  if active then
    if load_raw_diff then
      err, raw_diff = load_raw_diff(active.id)
      if err then
        return err
      end
    end
    local raw
    err, raw = async.await(conduit.call('differential.querydiffs', { ids = { active.id } }))
    if err then
      return err
    end
    local diff = raw and raw[tostring(active.id)]
    for _, ch in ipairs(diff and diff.changes or {}) do
      local status = CHANGE_STATUS[tonumber(ch.type)]
      if status then
        files[#files + 1] = {
          status = status,
          path = ch.currentPath,
          old_path = (status == 'R' or status == 'C') and ch.oldPath or nil,
        }
      end
    end
    table.sort(files, function(a, b)
      return a.path < b.path
    end)
  end

  local inlines, by_comment, timeline = {}, {}, {}
  for i = #xacts, 1, -1 do -- transaction.search returns newest first
    local t = xacts[i]
    local c = latest_comment(t)
    if t.type == 'inline' and c and t.fields and t.fields.path then
      local entry = { author = name(t.authorPHID), text = c.text, date = c.date }
      local thread = t.fields.replyToCommentPHID and by_comment[t.fields.replyToCommentPHID]
      if thread then
        table.insert(thread.comments, entry)
      else
        thread = {
          path = t.fields.path,
          line = t.fields.line or 1,
          length = math.max(t.fields.length or 1, 1),
          diff_id = t.fields.diff and t.fields.diff.id,
          comment_id = c.id,
          done = t.fields.isDone or false,
          comments = { entry },
        }
        inlines[thread.path] = inlines[thread.path] or {}
        table.insert(inlines[thread.path], thread)
      end
      if c.phid then
        by_comment[c.phid] = thread
      end
    elseif t.type == 'comment' and c and c.text:match('%S') then
      timeline[#timeline + 1] = { author = name(t.authorPHID), date = t.dateCreated, text = c.text }
    elseif ACTION_LABEL[t.type] then
      timeline[#timeline + 1] = { author = name(t.authorPHID), date = t.dateCreated, action = ACTION_LABEL[t.type] }
    end
  end
  for _, list in pairs(inlines) do
    table.sort(list, function(a, b)
      if a.line ~= b.line then
        return a.line < b.line
      end
      return (a.comments[1].date or 0) < (b.comments[1].date or 0)
    end)
  end

  local reviewers = {}
  for _, r in ipairs(reviewers_raw) do
    reviewers[#reviewers + 1] = { name = name(r.reviewerPHID), status = r.status, blocking = r.isBlocking }
  end

  return nil,
    {
      id = rev.id,
      phid = rev.phid,
      title = rev.fields.title or '',
      summary = rev.fields.summary or '',
      test_plan = rev.fields.testPlan or '',
      status = rev.fields.status and rev.fields.status.name or '?',
      closed = rev.fields.status and rev.fields.status.closed or false,
      author = name(rev.fields.authorPHID),
      uri = rev.fields.uri,
      reviewers = reviewers,
      diff_id = active and active.id,
      base = base,
      onto = onto,
      raw_diff = raw_diff,
      files = files,
      inlines = inlines,
      timeline = timeline,
    }
end

return M
