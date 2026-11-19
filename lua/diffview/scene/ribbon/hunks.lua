local api = vim.api
local M = {}

local flags = {
  ["indent-heuristic"] = "indent_heuristic",
  iblank = "ignore_blank_lines",
  iwhite = "ignore_whitespace_change",
  iwhiteall = "ignore_whitespace",
  iwhiteeol = "ignore_whitespace_change_at_eol",
}
local last_diffopt, last_options

---Read the options used by the source comparison, including native line matching.
function M.options()
  if vim.o.diffexpr ~= "" then
    return nil
  end
  local diffopt = vim.o.diffopt
  if diffopt == last_diffopt then
    return last_options
  end
  last_diffopt, last_options = diffopt, nil
  local options = { result_type = "indices", indent_heuristic = false }
  local internal = false
  for item in diffopt:gmatch("[^,]+") do
    local key, value = item:match("^([^:]+):(.+)$")
    if item == "icase" or item == "anchor" then
      return nil
    elseif item == "internal" then
      internal = true
    elseif flags[item] then
      options[flags[item]] = true
    elseif key == "algorithm" then
      options.algorithm = value
    elseif key == "linematch" then
      options.linematch = tonumber(value)
    end
  end
  if internal then
    last_options = options
  end
  return last_options
end

local function text(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" and api.nvim_buf_call(buf, vim.fn.wordcount).bytes == 0 then
    return ""
  end
  -- Serialize embedded NULs the same way as Neovim's internal diff.
  for i, line in ipairs(lines) do
    lines[i] = line:gsub("\n", "\0")
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.get(session, options)
  local a, b = session.a, session.b
  local tick_a, tick_b = api.nvim_buf_get_changedtick(a), api.nvim_buf_get_changedtick(b)
  if session.options ~= options or session.tick_a ~= tick_a or session.tick_b ~= tick_b then
    session.hunks = vim.text.diff(text(a), text(b), options)
    session.options, session.tick_a, session.tick_b = options, tick_a, tick_b
  end
  return session.hunks
end

return M
