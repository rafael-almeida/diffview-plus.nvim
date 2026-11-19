local geometry = require("diffview.scene.ribbon.geometry")

local api = vim.api
local ns = api.nvim_create_namespace("diffview.ribbon.canvas")
local M = {}

local colors = {
  add = { "DiffAdd", 0x51805b, 2 },
  delete = { "DiffDelete", 0x9d525a, 1 },
  change = { "DiffChange", 0x576fac, 4 },
}

function M.palette()
  local palette = {}
  for kind, color in pairs(colors) do
    local hl = api.nvim_get_hl(0, { name = color[1], link = false, create = false })
    palette[kind] = hl.bg or hl.fg or color[2]
  end
  local add, delete = "DiffviewRibbonInsertionUnderline", "DiffviewRibbonDeletionUnderline"
  api.nvim_set_hl(0, add, { underline = true, sp = palette.add })
  api.nvim_set_hl(0, delete, { underline = true, sp = palette.delete })
  return palette,
    { add = api.nvim_get_hl_id_by_name(add), delete = api.nvim_get_hl_id_by_name(delete) }
end

function M.clear(session)
  local buf = session.surface.buf
  if session.frame and api.nvim_buf_is_loaded(buf) then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  end
  session.frame = nil
end

function M.draw(session, area, frame, lines, marks)
  if session.frame == frame then
    return
  end
  session.frame = frame
  local buf = session.surface.buf
  local offset = area.offset
  local padded = {}
  for i = 1, offset do
    padded[i] = ""
  end
  vim.list_extend(padded, lines)
  api.nvim_buf_set_lines(buf, 0, -1, false, padded)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    api.nvim_buf_set_extmark(
      buf,
      ns,
      mark[1] + offset,
      mark[2],
      { end_col = mark[3], hl_group = mark[4] }
    )
  end
end

function M.cells(area, ribbons, palette)
  local columns = geometry.columns(ribbons, area.width, area.height, 1)
  local lines, marks, groups = {}, {}, {}
  for y = 0, area.height - 1 do
    local line, offset = {}, 0
    for x = 1, area.width do
      local top, bottom
      local best_top, best_bottom = 0, 0
      for _, span in ipairs(columns[x]) do
        local a, b, kind = span[1], span[2], span[3]
        local upper = math.min(b, y + 0.5) - math.max(a, y)
        local lower = math.min(b, y + 1) - math.max(a, y + 0.5)
        if upper > best_top then
          top, best_top = kind, upper
        end
        if lower > best_bottom then
          bottom, best_bottom = kind, lower
        end
      end
      local ch = " "
      if top or bottom then
        local fg, bg = top or bottom, top and bottom or nil
        ch = top and bottom and (top == bottom and "█" or "▀") or top and "▀" or "▄"
        local group = "DiffviewRibbonCell_" .. fg .. "_" .. (bg or "none")
        if not groups[group] then
          api.nvim_set_hl(0, group, {
            fg = palette[fg],
            bg = bg and palette[bg],
            ctermfg = colors[fg][3],
            ctermbg = bg and colors[bg][3],
          })
          groups[group] = true
        end
        marks[#marks + 1] = { y, offset, offset + #ch, group }
      end
      line[x] = ch
      offset = offset + #ch
    end
    lines[y + 1] = table.concat(line)
  end
  return lines, marks
end

return M
