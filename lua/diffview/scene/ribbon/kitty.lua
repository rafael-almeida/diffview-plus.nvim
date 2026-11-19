local api = vim.api
local geometry = require("diffview.scene.ribbon.geometry")
local diacritics = require("diffview.scene.ribbon.diacritics")
local raster = require("diffview.scene.ribbon.raster")
local M = {}

local esc, st = "\27_G", "\27\\"
local placeholder = vim.fn.nr2char(0x10EEEE)
local image_id = vim.uv.hrtime() % 0xFFFFFF

local function next_id()
  image_id = image_id % 0xFFFFFF + 1
  return image_id
end

local function send(bytes)
  return pcall(api.nvim_ui_send, bytes)
end

local function delete(id)
  send(esc .. "a=d,d=I,q=2,i=" .. id .. st)
end

function M.clear(session)
  if session.image then
    delete(session.image.id)
    session.image = nil
  end
end

local function eligible()
  local uis = api.nvim_list_uis()
  return api.nvim_ui_send
    and vim.o.termguicolors
    and #uis == 1
    and uis[1].stdout_tty
    and not vim.env.TMUX
    and not vim.env.STY
    and not vim.env.ZELLIJ
end

function M.ready(state, refresh)
  if not eligible() then
    state.status, state.id = nil, nil
    return false
  end
  if not state.status then
    local id = next_id()
    state.status, state.id = "probing", id
    if not send(esc .. ("a=q,U=1,i=%d,s=1,v=1,f=24;AAAA"):format(id) .. st) then
      state.status = "unavailable"
    else
      vim.defer_fn(function()
        if state.id == id and state.status == "probing" then
          state.status = "unavailable"
          refresh()
        end
      end, 500)
    end
  end
  return state.status == "ready"
end

function M.response(state, session, sequence)
  if type(sequence) ~= "string" then
    return
  end
  local keys, message = sequence:match("^\27_G([^;]+);([^\27]+)")
  local id = keys and tonumber(keys:match("%f[%w]i=(%d+)"))
  if id and id == state.id and state.status == "probing" then
    state.status = message == "OK" and "ready" or "unavailable"
    return true
  end
  if id and session and session.image and id == session.image.id and message ~= "OK" then
    state.status = "unavailable"
    return true
  end
end

-- CSI cell-size responses are not forwarded by Neovim 0.12. Use the
-- terminal's winsize when available, with a configurable pixel estimate.
local ffi_ok, ffi = pcall(require, "ffi")
local ctype_ready = ffi_ok
  and (ffi.os == "Linux" or ffi.os == "OSX")
  and pcall(
    ffi.cdef,
    [[
  struct diffview_ribbon_winsize { unsigned short rows, cols, width, height; };
  int ioctl(int, unsigned long, ...);
]]
  )

local function tty_cell_size()
  if not ctype_ready then
    return
  end
  local size = ffi.new("struct diffview_ribbon_winsize[1]")
  local request = ffi.os == "OSX" and 0x40087468 or 0x5413
  for fd = 0, 2 do
    if ffi.C.ioctl(fd, request, size) == 0 then
      local s = size[0]
      if s.rows > 0 and s.cols > 0 and s.width >= s.cols and s.height >= s.rows then
        return { math.floor(s.width / s.cols), math.floor(s.height / s.rows) }
      end
    end
  end
end

local function occupied_rows(columns, cell_height, rows)
  local first, last = rows, 0
  for _, spans in ipairs(columns) do
    for _, span in ipairs(spans) do
      first = math.min(first, math.floor(span[1] / cell_height))
      last = math.max(last, math.ceil(span[2] / cell_height))
    end
  end
  return first, last
end

local function fully_visible(ribbons, height)
  for _, r in ipairs(ribbons) do
    -- Leave a row at either edge for thin endpoints that extend past a boundary.
    if math.min(r[1], r[3]) <= 0 or math.max(r[2], r[4]) >= height then
      return false
    end
  end
  return true
end

local function translation(image, ribbons, layout, visible)
  if
    not image
    or image.layout ~= layout
    or not image.visible
    or not visible
    or #image.ribbons ~= #ribbons
    or #ribbons == 0
  then
    return
  end
  local shift = ribbons[1][1] - image.ribbons[1][1]
  if shift == 0 or shift % 1 ~= 0 then
    return
  end
  for i, r in ipairs(ribbons) do
    local previous = image.ribbons[i]
    if
      r.kind ~= previous.kind
      or r.left_anchor ~= previous.left_anchor
      or r.right_anchor ~= previous.right_anchor
    then
      return
    end
    for endpoint = 1, 4 do
      if r[endpoint] - previous[endpoint] ~= shift then
        return
      end
    end
  end
  return shift
end

local function place(image, key, height)
  local group = "DiffviewRibbonKitty"
  api.nvim_set_hl(0, group, { fg = image.id })
  local lines, marks = {}, {}
  for row = 1, height do
    lines[row] = ""
  end
  for row, text in ipairs(image.placeholders) do
    local target = image.first + row
    lines[target] = text
    marks[row] = { target - 1, 0, #text, group }
  end
  image.key, image.lines, image.marks = key, lines, marks
  return key, lines, marks
end

function M.frame(session, lane, ribbons, palette, key, cell_px)
  if lane.width > #diacritics then
    return
  end
  local cell = cell_px
  if not cell then
    local ok, measured = pcall(tty_cell_size)
    cell = (ok and measured) or { 10, 20 }
  end
  local w, h = lane.width * cell[1], lane.height * cell[2]
  local layout = table.concat({
    lane.width,
    lane.height,
    cell[1],
    cell[2],
    palette.add or "",
    palette.delete or "",
    palette.change or "",
  }, "/")
  key = "kitty/" .. layout .. "/" .. key
  local image = session.image
  if image and image.key == key then
    return key, image.lines, image.marks
  end

  local visible = fully_visible(ribbons, lane.height)
  local shift = translation(image, ribbons, layout, visible)
  if shift then
    -- Keep image-local placeholder coordinates and move their canvas rows.
    image.first = image.first + shift
    image.ribbons = ribbons
    return place(image, key, lane.height)
  end

  local columns = geometry.columns(ribbons, w, h, cell[2])
  local first, last = occupied_rows(columns, cell[2], lane.height)
  local rows = last - first
  local image_height = rows * cell[2]
  if rows <= 0 or rows > #diacritics or w * image_height > 750000 then
    return
  end
  local id = next_id()
  local data = vim.base64.encode(raster.paint(columns, palette, first * cell[2], last * cell[2]))
  local commands = {}
  for i = 1, #data, 4096 do
    local more = i + 4096 <= #data and 1 or 0
    local command = i == 1
        and ("a=T,U=1,p=1,f=32,q=1,i=%d,s=%d,v=%d,c=%d,r=%d,m=%d"):format(
          id,
          w,
          image_height,
          lane.width,
          rows,
          more
        )
      or ("m=%d"):format(more)
    commands[#commands + 1] = esc .. command .. ";" .. data:sub(i, i + 4095) .. st
  end
  if not send(table.concat(commands)) then
    delete(id)
    return nil, nil, nil, "transport"
  end

  M.clear(session)
  local placeholders = {}
  for row = 1, rows do
    local chars = {}
    for col = 1, lane.width do
      chars[col] = placeholder .. diacritics[row] .. diacritics[col]
    end
    placeholders[row] = table.concat(chars)
  end
  local image = {
    id = id,
    layout = layout,
    first = first,
    ribbons = ribbons,
    visible = visible,
    placeholders = placeholders,
  }
  session.image = image
  -- Refresh the virtual placement after Neovim publishes its placeholder cells.
  vim.defer_fn(function()
    if session.image == image then
      send(esc .. ("a=p,U=1,q=1,p=1,i=%d,c=%d,r=%d;"):format(id, lane.width, rows) .. st)
    end
  end, 16)
  return place(image, key, lane.height)
end

return M
