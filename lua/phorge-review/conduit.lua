-- Conduit API client. Credentials are discovered the same way `arc` does it:
-- `phabricator.uri` from the nearest `.arcconfig`, token from `~/.arcrc`.
local async = require('phorge-review.async')
local config = require('phorge-review.config')
local util = require('phorge-review.util')

local M = {}

local conn

local function discover_uri(cwd)
  local found = vim.fs.find('.arcconfig', { upward = true, path = cwd, type = 'file' })[1]
  local arcconfig = found and util.read_json(found)
  return arcconfig and (arcconfig['phabricator.uri'] or arcconfig['conduit_uri'])
end

local function discover_token(uri)
  local arcrc = util.read_json(vim.fs.normalize(config.options.arcrc))
  local hosts = arcrc and arcrc.hosts or {}
  local host = hosts[uri .. 'api/'] or hosts[uri]
  return host and host.token
end

--- Returns `{ uri = ..., token = ... }` or `nil, err`.
function M.connection(cwd)
  if conn then
    return conn
  end
  local uri = config.options.uri or discover_uri(cwd or vim.uv.cwd())
  if not uri then
    return nil, 'no `phabricator.uri` in .arcconfig; set `uri` in require("phorge-review").setup()'
  end
  uri = uri:gsub('/+$', ''):gsub('/api$', '') .. '/'
  local token = config.options.token or os.getenv('PHORGE_REVIEW_TOKEN') or discover_token(uri)
  if not token then
    return nil, ('no API token for %s in %s; run `arc install-certificate`'):format(uri, config.options.arcrc)
  end
  conn = { uri = uri, token = token }
  return conn
end

function M.reset()
  conn = nil
end

--- Returns a thunk for `async.await` that calls `method` and yields `err, result`.
function M.call(method, params)
  return function(cb)
    local c, err = M.connection()
    if not c then
      return cb(err)
    end
    params = vim.deepcopy(params or {})
    params.__conduit__ = { token = c.token }
    vim.system({
      'curl',
      '-sS',
      '-X',
      'POST',
      c.uri .. 'api/' .. method,
      '--data-urlencode',
      'params@-',
      '--data-urlencode',
      'output=json',
    }, { stdin = vim.json.encode(params), text = true }, function(out)
      if out.code ~= 0 then
        return cb(('curl failed (%d): %s'):format(out.code, vim.trim(out.stderr or '')))
      end
      local ok, body = pcall(vim.json.decode, out.stdout, { luanil = { object = true, array = true } })
      if not ok or type(body) ~= 'table' then
        return cb('unexpected response from ' .. method .. ': ' .. (out.stdout or ''):sub(1, 200))
      end
      if body.error_code then
        return cb(('%s: %s'):format(body.error_code, body.error_info))
      end
      cb(nil, body.result)
    end)
  end
end

--- Follows the cursor of a `*.search` method. Must run inside `async.run`.
function M.search_all(method, params)
  local data, after = {}, nil
  repeat
    local err, res = async.await(M.call(method, vim.tbl_extend('force', params, { after = after })))
    if err then
      return err
    end
    vim.list_extend(data, res.data or {})
    after = res.cursor and res.cursor.after
  until not after
  return nil, data
end

return M
