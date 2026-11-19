local M = {}

function M.columns(ribbons, width, height, scale)
  local columns = {}
  for x = 1, width do
    local t = width == 1 and 0.5 or (x - 1) / (width - 1)
    local blend = t * t * (3 - 2 * t)
    local spans = {}
    for _, r in ipairs(ribbons) do
      local left_top, left_bottom = r[1] * scale, r[2] * scale
      local right_top, right_bottom = r[3] * scale, r[4] * scale
      local min_height = scale / 3
      if (r.left_anchor or r.right_anchor) and scale > 1 then
        -- The image meets the terminal underline just above the row boundary.
        min_height = math.max(1, scale / 18)
        if r.left_anchor then
          left_bottom = left_bottom - min_height
          left_top = left_bottom - min_height
        else
          right_bottom = right_bottom - min_height
          right_top = right_bottom - min_height
        end
      end
      local top = left_top + (right_top - left_top) * blend
      local bottom = left_bottom + (right_bottom - left_bottom) * blend
      if bottom >= 0 and top <= height and bottom - top < min_height then
        local half = min_height / 2
        local center = math.max(half, math.min(height - half, (top + bottom) / 2))
        top, bottom = center - half, center + half
      end
      if bottom > 0 and top < height then
        spans[#spans + 1] = { math.max(0, top), math.min(height, bottom), r.kind }
      end
    end
    columns[x] = spans
  end
  return columns
end

return M
