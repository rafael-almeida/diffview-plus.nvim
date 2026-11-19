local has_ffi, ffi = pcall(require, "ffi")
local little_endian = not has_ffi or ffi.abi("le")
local alpha_place = little_endian and 0x1000000 or 1
local pixels, coverage
local pixel_capacity, coverage_capacity = 0, 0
local double_size = has_ffi and ffi.sizeof("double") or 0
local M = {}

local function storage(size, height)
  if not has_ffi then
    return {}
  end
  if size > pixel_capacity then
    pixel_capacity = math.max(size, pixel_capacity * 2)
    pixels = ffi.new("uint32_t[?]", pixel_capacity)
  end
  if height > coverage_capacity then
    coverage_capacity = math.max(height, coverage_capacity * 2)
    coverage = ffi.new("double[?]", coverage_capacity)
  end
  ffi.fill(pixels, size * 4)
  return pixels
end

local function pack_colors(palette)
  local colors = {}
  for kind, rgb in pairs(palette) do
    if little_endian then
      local red, green, blue = math.floor(rgb / 65536), math.floor(rgb / 256) % 256, rgb % 256
      colors[kind] = red + green * 256 + blue * 65536
    else
      colors[kind] = rgb * 256
    end
  end
  return colors
end

function M.paint(columns, palette, top, bottom)
  local width, height = #columns, bottom - top
  local size = width * height
  if size <= 0 then
    return ""
  end
  local image = storage(size, height)
  local colors = pack_colors(palette)
  for x, spans in ipairs(columns) do
    if #spans > 0 then
      local strength
      if has_ffi then
        ffi.fill(coverage, height * double_size)
        strength = coverage
      else
        strength = {}
      end
      for _, span in ipairs(spans) do
        local start, stop = span[1], span[2]
        local color = colors[span[3]]
        local first = math.max(top, math.floor(start))
        local last = math.min(bottom, math.ceil(stop)) - 1
        for y = first, last do
          local row = y - top
          local amount = math.min(y + 1, stop) - math.max(y, start)
          -- Preserve the first span on a tie, including at antialiased edges.
          if amount > (strength[row] or 0) then
            strength[row] = amount
            image[row * width + x - 1] = color + math.floor(amount * 225 + 0.5) * alpha_place
          end
        end
      end
    end
  end
  if has_ffi then
    return ffi.string(image, size * 4)
  end
  local bytes = {}
  for i = 0, size - 1 do
    local value = image[i] or 0
    bytes[i + 1] = string.char(
      value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 0x1000000)
    )
  end
  return table.concat(bytes)
end

return M
