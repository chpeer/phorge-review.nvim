-- Test runner. Without arguments it runs every tests/*_spec.lua in a fresh
-- headless Neovim; with a spec path it runs that spec in this process.
--
--   nvim --headless -u NONE -i NONE -l tests/run.lua [tests/foo_spec.lua]
--
-- A spec file returns a list of `{ name, fn }`; a test fails when `fn` errors.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local spec = _G.arg[1]

if not spec then
  local failed = 0
  for _, file in ipairs(vim.fn.glob(root .. '/tests/*_spec.lua', false, true)) do
    local cmd = { vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-l', root .. '/tests/run.lua', file }
    local r = vim.system(cmd, { text = true }):wait()
    io.stdout:write(r.stdout or '', r.stderr or '')
    if r.code ~= 0 then
      failed = failed + 1
    end
  end
  io.stdout:write(failed == 0 and 'all specs passed\n' or ('%d spec file(s) failed\n'):format(failed))
  os.exit(failed == 0 and 0 or 1)
end

vim.opt.rtp:prepend(root)
package.path = root .. '/tests/?.lua;' .. package.path
-- Keep drafts written by the tests out of the user's state directory.
vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.cmd.runtime('plugin/phorge-review.lua')

local h = require('helpers')
local failures = 0
io.stdout:write(vim.fn.fnamemodify(spec, ':t') .. '\n')
for _, t in ipairs(dofile(spec)) do
  local ok, err = xpcall(t[2], debug.traceback)
  h.reset()
  if ok then
    io.stdout:write('  ok    ' .. t[1] .. '\n')
  else
    failures = failures + 1
    io.stdout:write('  FAIL  ' .. t[1] .. '\n' .. tostring(err):gsub('\n', '\n        ') .. '\n')
  end
end
os.exit(failures == 0 and 0 or 1)
