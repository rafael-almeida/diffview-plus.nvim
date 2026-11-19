local actions = require("diffview.actions")
local config = require("diffview.config")
local helpers = require("diffview.tests.helpers")
local lib = require("diffview.lib")

local api = vim.api
if vim.fn.has("nvim-0.12") == 0 then
  return
end

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/diffview.lua")

local function wait_for(predicate)
  assert.is_true(vim.wait(3000, predicate, 10), "Timed out waiting for the ribbon view")
end

local function line_attrs(win, line)
  local pos = vim.fn.screenpos(win, line, 1)
  local _, col = unpack(api.nvim_win_get_position(win))
  assert.is_true(pos.row > 0 and pos.col > 0)
  return vim.fn.screenattr(pos.row, pos.col),
    vim.fn.screenattr(pos.row, col + api.nvim_win_get_width(win))
end

describe("built-in horizontal ribbons", function()
  local repo, original_config, original_diffopt, original_cwd, view
  local native = "internal,filler,closeoff,linematch:40"

  before_each(function()
    original_config, original_diffopt, original_cwd =
      config.get_config(), vim.o.diffopt, vim.fn.getcwd()
    vim.o.diffopt = native
    repo = helpers.init_repo()
    vim.cmd.cd(repo)
    vim.fn.writefile({ "first", "unchanged", "last" }, "a.txt")
    vim.fn.writefile({ "before", "line" }, "b.txt")
    vim.fn.writefile({ "first", "second", "third", "fourth", "deleted", "sixth" }, "c.txt")
    helpers.commit(repo, "base")
    vim.fn.writefile({ "first", "inserted", "unchanged", "last" }, "a.txt")
    vim.fn.writefile({ "after", "line" }, "b.txt")
    vim.fn.writefile({ "first", "second", "inserted", "third", "fourth", "sixth" }, "c.txt")
    config.setup({
      use_icons = false,
      watch_index = false,
      view = {
        ribbon = { enabled = true, renderer = "cells" },
        cycle_layouts = { default = { "diff2_horizontal", "diff2_vertical" } },
      },
    })
  end)

  after_each(function()
    helpers.close_view(view)
    view = nil
    config.setup(original_config)
    vim.o.diffopt = original_diffopt
    vim.cmd.cd(original_cwd)
    vim.fn.delete(repo, "rf")
  end)

  local function session()
    local attached = view.ribbon.session
    return attached and attached.frame and attached
  end

  local function open(args)
    vim.cmd("DiffviewOpen " .. (args or "HEAD"))
    view = assert(lib.get_current_view())
    wait_for(session)
    return session()
  end

  it("renders the new source pair on file switches and preserves native hunk operations", function()
    local first = open()
    local layout = view.cur_layout
    assert.equals(2, #layout.windows)
    assert.equal(first.left, layout.a.id)
    assert.equal(first.right, layout.b.id)
    assert.equal(first.a, api.nvim_win_get_buf(first.left))
    assert.equal(first.b, api.nvim_win_get_buf(first.right))
    assert.equal(6, api.nvim_win_get_width(first.surface.win))
    assert.equal(native, vim.o.diffopt)
    assert.is_false(vim.wo[first.surface.win].diff)
    assert.is_false(vim.wo[first.surface.win].scrollbind)
    assert.equal(
      1,
      api.nvim_win_call(first.left, function()
        return vim.fn.diff_filler(2)
      end)
    )

    api.nvim_set_current_win(first.left)
    vim.cmd("wincmd l")
    wait_for(function()
      return api.nvim_get_current_win() == first.right
    end)
    vim.cmd("wincmd =")
    vim.cmd("redraw!")
    wait_for(function()
      return api.nvim_win_get_width(first.surface.win) == 6
    end)

    api.nvim_win_call(first.right, function()
      vim.cmd("2diffget " .. first.a)
    end)
    assert.same({ "first", "unchanged", "last" }, api.nvim_buf_get_lines(first.b, 0, -1, false))
    api.nvim_win_call(first.right, vim.cmd.undo)

    view:next_file()
    wait_for(function()
      return session() and session() ~= first
    end)
    local second = session()
    assert.equal(first.surface.win, second.surface.win)
    assert.not_equal(first.a, second.a)
    assert.not_equal(first.b, second.b)
    assert.is_nil(first.source)

    actions.cycle_layout()
    wait_for(function()
      return view.cur_layout.name == "diff2_vertical"
    end)
    assert.is_false(api.nvim_win_is_valid(second.surface.win))
    assert.equal(native, vim.o.diffopt)

    actions.cycle_layout()
    wait_for(session)
    local third = session()
    vim.cmd("tabprevious")
    assert.is_false(api.nvim_win_is_valid(third.surface.win))
    assert.equal(native, vim.o.diffopt)
    local refreshed
    view.emitter:once("files_updated", function()
      refreshed = true
    end)
    vim.cmd("tabnext")
    wait_for(function()
      return session() and refreshed
    end)

    local updated = "internal,filler,linematch:80"
    vim.cmd("set diffopt=" .. updated)
    wait_for(function()
      return session() and session().options.linematch == 80
    end)
    assert.equal(updated, vim.o.diffopt)
    vim.cmd("DiffviewClose")
    assert.equal(updated, vim.o.diffopt)
  end)

  it("draws both thin source underlines with native filler and a custom status column", function()
    local frame = open("HEAD -- c.txt")
    local left, right = frame.left, frame.right
    assert.equal("1", vim.wo[left].foldcolumn)
    assert.equal("1", vim.wo[right].foldcolumn)
    vim.cmd("redraw!")
    local left_text, left_padding = line_attrs(left, 2)
    local right_text, right_padding = line_attrs(right, 5)
    assert.equal(left_text, left_padding)
    assert.equal(right_text, right_padding)
    assert.not_equal(left_text, line_attrs(left, 1))
    assert.not_equal(right_text, line_attrs(right, 4))
    assert.is_true(api.nvim_get_hl(0, { name = "DiffviewRibbonInsertionUnderline" }).underline)
    assert.is_true(api.nvim_get_hl(0, { name = "DiffviewRibbonDeletionUnderline" }).underline)

    vim.wo[right].statuscolumn = "%C%s%l"
    vim.wo[right].winbar = "Custom window bar"
    api.nvim_exec_autocmds("WinResized", { group = view.ribbon.group })
    wait_for(function()
      return api.nvim_buf_get_lines(frame.surface.buf, 0, 1, false)[1] == ""
    end)
    assert.equal("%C%s%l", vim.wo[right].statuscolumn)
    assert.equal(native, vim.o.diffopt)
  end)

  it("handles stage and unstage using the existing working tree and index views", function()
    open("-- c.txt")
    actions.toggle_stage_entry()
    wait_for(function()
      return session() and view.cur_entry.kind == "staged"
    end)
    assert.equal("c.txt", vim.trim(helpers.run({ "git", "diff", "--cached", "--name-only" }, repo)))
    actions.toggle_stage_entry()
    wait_for(function()
      return session() and view.cur_entry.kind == "working"
    end)
    assert.equal("", helpers.run({ "git", "diff", "--cached", "--name-only" }, repo))
  end)

  it("handles one-sided Git additions without adding a source underline", function()
    vim.fn.writefile({ "new file", "last line" }, "added.txt")
    helpers.run({ "git", "add", "added.txt" }, repo)
    local frame = open("HEAD -- added.txt")
    assert.is_true(view.cur_layout.a.file.nulled)
    assert.is_nil(next(frame.source[frame.left].anchors))
    assert.is_nil(next(frame.source[frame.right].anchors))
  end)

  it("reuses a Kitty frame and falls back to cells when image transport fails", function()
    local kitty = require("diffview.scene.ribbon.kitty")
    local original_ready, original_send = kitty.ready, api.nvim_ui_send
    local uploads, placements, failure = 0, 0, false
    kitty.ready = function(probe)
      return probe.status ~= "unavailable"
    end
    api.nvim_ui_send = function(bytes)
      if bytes:find("a=T,U=1", 1, true) then
        uploads = uploads + 1
        if failure then
          error("simulated transport failure")
        end
      elseif bytes:find("a=p,U=1", 1, true) then
        placements = placements + 1
      end
    end
    local opts = config.get_config().view.ribbon
    opts.renderer = "kitty"
    opts.cell_px = { 10, 20 }

    local ok, err = xpcall(function()
      local frame = open("HEAD -- a.txt")
      assert.is_true(vim.startswith(frame.frame, "kitty/"))
      wait_for(function()
        return placements == 1
      end)
      assert.equal(1, uploads)
      view.ribbon:render()
      assert.equal(1, uploads)
      failure = true
      api.nvim_buf_set_lines(frame.b, 2, 2, false, { "one more insertion" })
      api.nvim_exec_autocmds("DiffUpdated", { group = view.ribbon.group })
      wait_for(function()
        return session() and vim.startswith(session().frame, "cells/")
      end)
      assert.equal(2, uploads)
      assert.is_nil(frame.image)
    end, debug.traceback)
    kitty.ready, api.nvim_ui_send = original_ready, original_send
    if not ok then
      error(err)
    end
  end)

  it("recovers from narrow views and dismisses a closed gutter", function()
    local first = open()
    api.nvim_win_set_width(view.panel.winid, vim.o.columns - 19)
    vim.cmd("redraw!")
    api.nvim_exec_autocmds("WinResized", { group = view.ribbon.group })
    wait_for(function()
      return view.cur_layout.gutter == nil
    end)
    assert.is_false(api.nvim_win_is_valid(first.surface.win))

    api.nvim_win_set_width(view.panel.winid, 22)
    vim.cmd("redraw!")
    api.nvim_exec_autocmds("WinResized", { group = view.ribbon.group })
    wait_for(session)
    api.nvim_win_close(session().surface.win, true)
    wait_for(function()
      return view.cur_layout.gutter == nil
    end)
    assert.equal(native, vim.o.diffopt)
    assert.is_true(view.cur_layout:is_valid())
  end)

  it("uses the standard source view under an unsupported native diff option", function()
    open()
    vim.cmd("set diffopt+=icase")
    wait_for(function()
      return view.cur_layout.gutter == nil
    end)
    assert.is_true(vim.wo[view.cur_layout.a.id].diff)
    assert.is_true(vim.wo[view.cur_layout.b.id].diff)
    assert.equal(native .. ",icase", vim.o.diffopt)
    vim.cmd("set diffopt-=icase")
    wait_for(session)
    assert.equal(native, vim.o.diffopt)
  end)

  it("recreates the gutter after recovery of a closed source pane", function()
    local first = open()
    api.nvim_win_close(first.left, true)
    view:ensure_layout()
    wait_for(function()
      return session() and session() ~= first
    end)
    local second = session()
    assert.is_false(api.nvim_win_is_valid(first.surface.win))
    assert.equal(view.cur_layout.a.id, second.left)
    assert.equal(view.cur_layout.b.id, second.right)
    assert.equal(first.a, second.a)
    assert.equal(first.b, second.b)
  end)

  it("renders in file history", function()
    helpers.commit(repo, "history change")
    vim.cmd("DiffviewFileHistory c.txt")
    view = assert(lib.get_current_view())
    wait_for(session)
    assert.is_true(api.nvim_win_get_height(session().surface.win) < vim.o.lines - 4)
    assert.equal(native, vim.o.diffopt)
  end)
end)
