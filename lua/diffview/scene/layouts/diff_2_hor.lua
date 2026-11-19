local async = require("diffview.async")
local Diff2 = require("diffview.scene.layouts.diff_2").Diff2
local oop = require("diffview.oop")

local api = vim.api
local await = async.await

local M = {}

---@class diffview.RibbonSurface
---@field win integer
---@field buf integer

---@class Diff2Hor : Diff2
---@field gutter diffview.RibbonSurface?
local Diff2Hor = oop.create_class("Diff2Hor", Diff2)

Diff2Hor.name = "diff2_horizontal"

---@param opt Diff2.init.Opt
function Diff2Hor:init(opt)
  self:super(opt)
end

---@override
---@param self Diff2Hor
---@param pivot integer?
Diff2Hor.create = async.void(function(self, pivot)
  await(self:create_wins(pivot, {
    { "a", "aboveleft vsp" },
    { "b", "aboveleft vsp" },
  }, { "a", "b" }))
end)

---@param width integer
---@return diffview.RibbonSurface
function Diff2Hor:open_gutter(width)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local ok, win = pcall(api.nvim_open_win, buf, false, {
    win = self.b.id,
    split = "left",
    width = width,
    style = "minimal",
    focusable = false,
    mouse = false,
    noautocmd = true,
  })
  if not ok then
    api.nvim_buf_delete(buf, { force = true })
    error(win)
  end
  local gutter = { win = win, buf = buf }
  self.gutter = gutter
  local wo = vim.wo[win]
  wo.diff = false
  wo.scrollbind = false
  wo.cursorbind = false
  wo.winfixbuf = true
  wo.winfixwidth = true
  wo.winbar = ""
  wo.statusline = " "
  wo.signcolumn = "no"
  wo.wrap = false
  wo.rightleft = false
  wo.foldenable = false
  return gutter
end

function Diff2Hor:close_gutter()
  local gutter = self.gutter
  self.gutter = nil
  if gutter and api.nvim_win_is_valid(gutter.win) then
    api.nvim_win_close(gutter.win, true)
  end
end

---@override
function Diff2Hor:destroy()
  self:close_gutter()
  Diff2.destroy(self)
end

M.Diff2Hor = Diff2Hor
return M
