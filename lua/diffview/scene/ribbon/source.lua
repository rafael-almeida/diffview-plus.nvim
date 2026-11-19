local api = vim.api
local ns = api.nvim_create_namespace("diffview.ribbon.source")
local M = {}

local function redraw(win)
  if api.nvim_win_is_valid(win) then
    if api.nvim__redraw then
      api.nvim__redraw({ win = win, valid = false })
    else
      vim.cmd("redraw!")
    end
  end
end

function M.clear(session)
  if session.source then
    session.source = nil
    redraw(session.left)
    redraw(session.right)
  end
end

function M.update(session, hunks, style)
  local previous = session.source
  if previous and previous.hunks == hunks and previous.style == style then
    return
  end

  local left = { buf = session.a, anchors = {}, group = style.add }
  local right = { buf = session.b, anchors = {}, group = style.delete }
  for _, h in ipairs(hunks) do
    -- An empty xdiff range starts at the gap after this line.
    if h[2] == 0 and h[1] > 0 then
      left.anchors[h[1] - 1] = true
    elseif h[4] == 0 and h[3] > 0 then
      right.anchors[h[3] - 1] = true
    end
  end
  session.source = { hunks = hunks, style = style, [session.left] = left, [session.right] = right }
  redraw(session.left)
  redraw(session.right)
end

function M.enable(get_session, on_redraw)
  local function pane_for(win, buf)
    local session = get_session()
    local pane = session and session.source and session.source[win]
    return pane and pane.buf == buf and pane
  end
  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, buf)
      local session = get_session()
      if session and (win == session.left or win == session.right) then
        on_redraw()
      end
      local pane = pane_for(win, buf)
      if not pane or not next(pane.anchors) then
        return false
      end
      pane.next_row = 0
    end,
    on_range = function(_, win, buf, first, _first_col, last, last_col)
      local pane = pane_for(win, buf)
      if not pane then
        return false
      end
      -- One highlight covers all wrapped screen rows of this buffer line.
      first = math.max(first, pane.next_row)
      local stop = last + (last_col > 0 and 1 or 0)
      if first >= stop then
        return
      end
      for row = first, stop - 1 do
        if pane.anchors[row] then
          api.nvim_buf_set_extmark(buf, ns, row, 0, {
            ephemeral = true,
            end_row = row + 1,
            end_col = 0,
            hl_group = pane.group,
            hl_eol = true,
          })
        end
      end
      pane.next_row = stop
    end,
  })
end

function M.disable()
  api.nvim_set_decoration_provider(ns, {})
end

return M
