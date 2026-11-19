local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local utils = require("diffview.utils")

local api = vim.api
local redraw_ns = api.nvim_create_namespace("diffview.ribbon")

---@class diffview.RibbonSnapshot
---@field tab integer
---@field generation integer
---@field left integer
---@field right integer
---@field a integer
---@field b integer
---@field surface diffview.RibbonSurface
---@field area { row: integer, col: integer, width: integer, height: integer, offset: integer, canvas_height: integer }

---@class diffview.RibbonAdapter
---@field width fun(): integer? # Requested gutter width, or nil if rendering is unavailable.
---@field attach fun(snapshot: diffview.RibbonSnapshot, request: fun())
---@field draw fun(snapshot: diffview.RibbonSnapshot)
---@field detach fun(snapshot: diffview.RibbonSnapshot) # Also called when attach fails.

---@class diffview.Ribbon
---@field view StandardView
---@field adapter diffview.RibbonAdapter
---@field group integer?
---@field generation integer
---@field committed boolean
---@field layout Diff2Hor?
---@field snapshot diffview.RibbonSnapshot?
---@field pending table?
---@field failed boolean?
---@field dismissed boolean?
local Ribbon = {}
Ribbon.__index = Ribbon

---@param view StandardView
---@param adapter diffview.RibbonAdapter
---@return diffview.Ribbon
function Ribbon.new(view, adapter)
  return setmetatable({ view = view, adapter = adapter, generation = 0, committed = false }, Ribbon)
end

function Ribbon:detach()
  self.generation = self.generation + 1
  local snapshot = self.snapshot
  self.snapshot = nil
  if snapshot then
    local ok, err = pcall(self.adapter.detach, snapshot)
    if not ok then
      utils.warn("Diffview ribbon cleanup: " .. tostring(err), true)
    end
  end
end

function Ribbon:release()
  self:detach()
  local layout = self.layout
  self.layout = nil
  if layout then
    local ok, err = pcall(layout.close_gutter, layout)
    if not ok then
      utils.warn("Diffview could not close the ribbon gutter: " .. tostring(err), true)
    end
  end
  if not self.view:set_ribbon_diffopt(false) then
    self.dismissed = true
  end
end

---@param keep_gutter boolean
function Ribbon:begin_swap(keep_gutter)
  self.committed = false
  if keep_gutter then
    self:detach()
  else
    self:release()
  end
end

function Ribbon:commit()
  self.committed = true
  self:request()
end

---@param gutter diffview.RibbonSurface
---@param left integer
---@param right integer
function Ribbon:handle_focus(gutter, left, right)
  api.nvim_create_autocmd("WinEnter", {
    group = self.group,
    buffer = gutter.buf,
    callback = function()
      if api.nvim_get_current_win() ~= gutter.win then
        return
      end
      local previous = vim.fn.win_getid(vim.fn.winnr("#"))
      local target = previous == left and right or left
      -- Defer until the window command finishes so :windo can iterate normally.
      vim.schedule(function()
        if api.nvim_get_current_win() == gutter.win and api.nvim_win_is_valid(target) then
          api.nvim_set_current_win(target)
        end
      end)
    end,
  })
end

function Ribbon:render()
  local view = self.view
  if self.failed or self.dismissed or (self.layout and not view:set_ribbon_diffopt(true)) then
    self:release()
    return
  end
  if not self.committed then
    return
  end

  local layout = view.cur_layout
  if view.nulled or layout.name ~= Diff2Hor.name or not layout:is_valid() then
    self:release()
    return
  end
  ---@cast layout Diff2Hor
  local left, right = layout.a.id, layout.b.id
  if not layout.a:is_file_open() or not layout.b:is_file_open() then
    self:release()
    return
  end
  local a, b = api.nvim_win_get_buf(left), api.nvim_win_get_buf(right)
  local tab = view.tabpage
  if
    a == b
    or api.nvim_win_get_tabpage(left) ~= tab
    or api.nvim_win_get_tabpage(right) ~= tab
    or not (vim.wo[left].diff or layout.a.file.nulled)
    or not (vim.wo[right].diff or layout.b.file.nulled)
    or vim.wo[left].rightleft
    or vim.wo[right].rightleft
  then
    self:release()
    return
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if win ~= left and win ~= right and vim.wo[win].diff then
      self:release()
      return
    end
  end

  local width = self.adapter.width()
  local l, r = vim.fn.getwininfo(left)[1], vim.fn.getwininfo(right)[1]
  local gutter = layout.gutter
  local gap = gutter
      and api.nvim_win_is_valid(gutter.win)
      and api.nvim_win_get_width(gutter.win) + 2
    or 1
  local available = r.wincol + r.width - l.wincol
  local min_left = math.max(vim.o.winminwidth, l.textoff + 12)
  local min_right = math.max(vim.o.winminwidth, r.textoff + 12)
  if
    not width
    or width < vim.o.winminwidth
    or width < 1
    or l.winrow ~= r.winrow
    or l.wincol + l.width + gap ~= r.wincol
    or available < min_left + min_right + width + 2
  then
    self:release()
    return
  end

  if not gutter then
    self.layout = layout
    local ok, err = pcall(layout.open_gutter, layout, width)
    if not ok then
      -- The editor can refuse a split even if the two pane widths look sufficient.
      self:release()
      utils.warn("Diffview could not allocate the ribbon gutter: " .. tostring(err), true)
      self.dismissed = true
      return
    end
    gutter = err
    self:handle_focus(gutter, left, right)
    local panes = available - width - 2
    local balanced = math.floor(panes * l.width / (l.width + r.width) + 0.5)
    api.nvim_win_set_width(left, math.min(panes - min_right, math.max(min_left, balanced)))
  end
  if api.nvim_win_get_width(gutter.win) ~= width then
    api.nvim_win_set_width(gutter.win, width)
  end
  if
    api.nvim_win_get_width(gutter.win) ~= width or api.nvim_win_get_buf(gutter.win) ~= gutter.buf
  then
    self:release()
    self.dismissed = true
    return
  end

  local g = vim.fn.getwininfo(gutter.win)[1]
  local row = math.max(l.winrow + l.winbar, r.winrow + r.winbar, g.winrow + g.winbar) - 1
  local bottom = math.min(
    l.winrow + l.winbar + l.height,
    r.winrow + r.winbar + r.height,
    g.winrow + g.winbar + g.height
  ) - 1
  if row >= bottom then
    self:release()
    return
  end

  local previous = self.snapshot
  if
    previous
    and (previous.left ~= left or previous.right ~= right or previous.a ~= a or previous.b ~= b)
  then
    self:detach()
  end
  view:set_ribbon_diffopt(true)
  local generation = self.generation
  local snapshot = {
    tab = tab,
    generation = generation,
    left = left,
    right = right,
    a = a,
    b = b,
    surface = gutter,
    area = {
      row = row,
      col = g.wincol - 1,
      width = g.width,
      height = bottom - row,
      offset = row - (g.winrow + g.winbar - 1),
      canvas_height = g.height,
    },
  }
  local attach = not self.snapshot
  self.snapshot = snapshot
  if attach then
    self.adapter.attach(snapshot, function()
      if generation == self.generation then
        self:request()
      end
    end)
  end
  self.adapter.draw(snapshot)
end

---@param scroll? boolean
function Ribbon:request(scroll)
  if
    not self.group
    or self.pending
    or self.view.closing:check()
    or not self.view:is_cur_tabpage()
  then
    return
  end
  local pending = {}
  self.pending = pending
  local function run()
    if self.pending ~= pending then
      return
    end
    self.pending = nil
    if self.view.closing:check() or not self.view:is_cur_tabpage() then
      return
    end
    local ok, err = xpcall(function()
      self:render()
    end, debug.traceback)
    if not ok then
      self.failed = true
      self:release()
      utils.warn("Diffview ribbon renderer failed: " .. tostring(err), true)
    end
  end
  if scroll then
    vim.defer_fn(run, 16)
  else
    vim.schedule(run)
  end
end

function Ribbon:start()
  if self.group then
    return
  end
  self.dismissed = false
  local group = api.nvim_create_augroup("DiffviewRibbon" .. self.view.tabpage, { clear = true })
  self.group = group
  local function refresh()
    self:request()
  end
  api.nvim_create_autocmd(
    { "BufWinEnter", "WinNew", "DiffUpdated", "WinResized", "VimResized", "ColorScheme" },
    {
      group = group,
      callback = refresh,
    }
  )
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "RibbonviewStateChanged",
    callback = function(ev)
      if ev.data and ev.data.retry then
        self.failed = false
        self.dismissed = false
        self:detach()
      end
      refresh()
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local gutter = self.layout and self.layout.gutter
      if gutter and tonumber(ev.match) == gutter.win then
        self.dismissed = true
      end
      refresh()
    end,
  })
  api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(ev)
      local snapshot = self.snapshot
      local win = tonumber(ev.match)
      if
        snapshot
        and (
          win == snapshot.left
          or win == snapshot.right
          or vim.v.event[tostring(snapshot.left)]
          or vim.v.event[tostring(snapshot.right)]
        )
      then
        self:request(true)
      end
    end,
  })
  api.nvim_set_decoration_provider(redraw_ns, {
    on_win = function(_, win)
      local snapshot = self.snapshot
      if snapshot and (win == snapshot.left or win == snapshot.right) then
        -- Opening a fold can change the visible rows without firing WinScrolled.
        self:request(true)
      end
      return false
    end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(ev)
      local snapshot = self.snapshot
      if snapshot and (ev.buf == snapshot.a or ev.buf == snapshot.b) then
        self:request(true)
      end
    end,
  })
  api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = {
      "diffopt",
      "diffexpr",
      "diff",
      "foldenable",
      "foldmethod",
      "foldlevel",
      "foldcolumn",
      "winbar",
      "wrap",
      "rightleft",
      "statuscolumn",
      "signcolumn",
      "number",
      "relativenumber",
      "numberwidth",
      "smoothscroll",
      "termguicolors",
      "ambiwidth",
      "background",
      "winminwidth",
    },
    callback = refresh,
  })
  refresh()
end

function Ribbon:stop()
  if self.group then
    api.nvim_set_decoration_provider(redraw_ns, {})
    api.nvim_del_augroup_by_id(self.group)
    self.group = nil
  end
  self.pending = nil
  self:release()
end

return Ribbon
