local api = vim.api
local M = {}

local function projection(win)
  local info = vim.fn.getwininfo(win)[1]
  local buf_last = api.nvim_buf_line_count(info.bufnr)
  local view = api.nvim_win_call(win, vim.fn.winsaveview)
  local first = view.topline - 1
  local height = api.nvim_win_text_height
  local skipped = view.skipcol > 0
      and height(win, {
        start_row = first,
        end_row = first,
        start_vcol = 0,
        end_vcol = view.skipcol,
      }).all
    or 0
  local origin = info.winrow + info.winbar - 1 + view.topfill - skipped
  local boundaries = {}

  -- A boundary is just before or after the virtual lines preceding a buffer line.
  local function boundary(row, after_virtual)
    local k = row * 2 + (after_virtual and 1 or 0)
    if boundaries[k] then
      return boundaries[k]
    end
    local pos = origin
    if row > first then
      pos = pos + height(win, { start_row = first, start_vcol = 0, end_row = row - 1 }).all
    elseif row < first then
      pos = pos - height(win, { start_row = row, end_row = first, end_vcol = 0 }).all
    end
    if row < buf_last then
      local fill = height(win, { start_row = row, end_row = row, end_vcol = 0 }).all
      if row == first and not after_virtual then
        pos = pos - fill
      elseif row ~= first and after_virtual then
        pos = pos + fill
      end
    end
    boundaries[k] = pos
    return pos
  end

  return {
    first = info.topline,
    last = info.botline,
    range = function(start, count)
      if count == 0 then
        local row = start > 0 and vim.fn.foldclosedend(start) or -1
        local y = boundary(row > 0 and row or start, false)
        return y, y
      end
      local ending = start + count - 1
      local fold_start, fold_end = vim.fn.foldclosed(start), vim.fn.foldclosedend(ending)
      return boundary((fold_start > 0 and fold_start or start) - 1, true),
        boundary(fold_end > 0 and fold_end or ending, false)
    end,
  }
end

function M.project(session, hunks, lane)
  local left, right = projection(session.left), projection(session.right)
  local ribbons = {}
  local top, bottom = lane.row, lane.row + lane.height
  local function side(p, start, count)
    if start + math.max(count - 1, 0) < p.first - 1 then
      return -1
    elseif start > p.last + 1 then
      return 1
    end
    return 0
  end

  -- foldclosed() queries the current window, so project all ranges for each
  -- pane in a single window call.
  local candidates = {}
  for _, h in ipairs(hunks) do
    local a, b = side(left, h[1], h[2]), side(right, h[3], h[4])
    if a == 0 or b == 0 or a ~= b then
      candidates[#candidates + 1] = h
    end
  end
  api.nvim_win_call(session.left, function()
    for i, h in ipairs(candidates) do
      local a, b = left.range(h[1], h[2])
      ribbons[i] = {
        a - top,
        b - top,
        kind = h[2] == 0 and "add" or h[4] == 0 and "delete" or "change",
        left_anchor = h[2] == 0 and h[1] > 0,
        right_anchor = h[4] == 0 and h[3] > 0,
      }
    end
  end)
  api.nvim_win_call(session.right, function()
    for i, h in ipairs(candidates) do
      local a, b = right.range(h[3], h[4])
      ribbons[i][3], ribbons[i][4] = a - top, b - top
    end
  end)
  return vim.tbl_filter(function(r)
    return math.max(r[2], r[4]) >= 0 and math.min(r[1], r[3]) <= bottom - top
  end, ribbons)
end

return M
