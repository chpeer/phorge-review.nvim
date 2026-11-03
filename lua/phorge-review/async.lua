-- Minimal coroutine helpers so Conduit calls can be written sequentially.
local M = {}

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    vim.schedule(function()
      vim.notify('[phorge-review] ' .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

--- Runs `fn` inside a new coroutine.
function M.run(fn)
  resume(coroutine.create(fn))
end

--- Suspends the current coroutine until `thunk` invokes its callback and
--- returns the callback's arguments. `thunk` is `function(cb) ... end`.
function M.await(thunk)
  local co = coroutine.running()
  assert(co, 'phorge-review: await() called outside of async.run()')
  thunk(function(...)
    local args = vim.F.pack_len(...)
    vim.schedule(function()
      resume(co, vim.F.unpack_len(args))
    end)
  end)
  return coroutine.yield()
end

return M
