local M = {}

function M.notify(msg, level)
  vim.notify('[phorge-review] ' .. msg, level or vim.log.levels.INFO)
end

function M.fmt_date(ts)
  if not ts then
    return ''
  end
  return os.date('%Y-%m-%d %H:%M', ts)
end

--- First line of `text`, truncated to `width` display cells.
function M.one_line(text, width)
  local line = (text or ''):match('[^\r\n]*%S[^\r\n]*') or ''
  if vim.fn.strdisplaywidth(line) > width then
    line = vim.fn.strcharpart(line, 0, math.max(width - 1, 1)) .. '…'
  end
  return line
end

--- Word-wraps `text` to `width` cells, preserving paragraph breaks.
function M.wrap(text, width)
  local out = {}
  text = (text or ''):gsub('\r', '')
  for para in vim.gsplit(text, '\n', { plain = true }) do
    if para == '' then
      out[#out + 1] = ''
    else
      local line = ''
      for word in para:gmatch('%S+') do
        if line == '' then
          line = word
        elseif vim.fn.strdisplaywidth(line .. ' ' .. word) > width then
          out[#out + 1] = line
          line = word
        else
          line = line .. ' ' .. word
        end
      end
      out[#out + 1] = line
    end
  end
  return out
end

function M.read_json(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local s = f:read('*a')
  f:close()
  local ok, v = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  if ok then
    return v
  end
end

function M.read_file(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local content = f:read('*a')
  f:close()
  return content
end

--- Writes `content` to `path`, creating its directory. A reader never sees a
--- partial file.
function M.write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local tmp = path .. '.tmp'
  local f = assert(io.open(tmp, 'wb'))
  f:write(content)
  f:close()
  assert(os.rename(tmp, path))
end

function M.write_json(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'w'))
  f:write(vim.json.encode(value))
  f:close()
end

return M
