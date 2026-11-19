local actions = require("diffview.actions")
local config = require("diffview.config")
local helpers = require("diffview.tests.helpers")
local lib = require("diffview.lib")

local api = vim.api

-- The gutter is optional on the fork's Neovim 0.10 and 0.11 test jobs.
if vim.fn.has("nvim-0.12") == 0 then
  return
end

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/diffview.lua")

local function wait_for(predicate)
  assert.is_true(vim.wait(3000, predicate, 10), "Timed out waiting for the ribbon view")
end

describe("horizontal ribbon gutter", function()
  local repo, original_config, original_diffopt, original_cwd, view
  local attaches, detaches, draws, requests, adapter
  local native = "internal,filler,closeoff,linematch:40"

  before_each(function()
    original_config, original_diffopt, original_cwd =
      config.get_config(), vim.o.diffopt, vim.fn.getcwd()
    vim.o.diffopt = native
    repo = helpers.init_repo()
    vim.cmd.cd(repo)
    vim.fn.writefile({ "first", "unchanged", "last" }, "a.txt")
    vim.fn.writefile({ "before", "line" }, "b.txt")
    helpers.commit(repo, "base")
    vim.fn.writefile({ "first", "inserted", "unchanged", "last" }, "a.txt")
    vim.fn.writefile({ "after", "line" }, "b.txt")
    attaches, detaches, draws, requests = {}, {}, {}, {}
    adapter = {
      width = function()
        return 6
      end,
      attach = function(snapshot, request)
        attaches[#attaches + 1] = snapshot
        requests[#requests + 1] = request
      end,
      draw = function(snapshot)
        draws[#draws + 1] = snapshot
      end,
      detach = function(snapshot)
        detaches[#detaches + 1] = snapshot
      end,
    }
  end)

  after_each(function()
    helpers.close_view(view)
    view = nil
    config.setup(original_config)
    vim.o.diffopt = original_diffopt
    vim.cmd.cd(original_cwd)
    vim.fn.delete(repo, "rf")
  end)

  local function open()
    config.setup({
      use_icons = false,
      diffopt = { context = 7 },
      view = {
        ribbon = adapter,
        cycle_layouts = { default = { "diff2_horizontal", "diff2_vertical" } },
      },
    })
    vim.cmd("DiffviewOpen HEAD")
    view = assert(lib.get_current_view())
    wait_for(function()
      return #attaches > 0
    end)
  end

  it("publishes the source pair together and invalidates callbacks after switching", function()
    open()
    local first = attaches[1]
    local layout = view.cur_layout
    assert.equals(2, #layout.windows)
    assert.equal(first.left, layout.a.id)
    assert.equal(first.right, layout.b.id)
    assert.equal(first.a, api.nvim_win_get_buf(first.left))
    assert.equal(first.b, api.nvim_win_get_buf(first.right))
    assert.equal(6, first.area.width)
    assert.equal("internal,closeoff,context:7", vim.o.diffopt)
    assert.is_false(vim.wo[first.surface.win].diff)
    assert.is_false(vim.wo[first.surface.win].scrollbind)

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
      return #attaches == 2
    end)
    local second = attaches[2]
    assert.equal(first.surface.win, second.surface.win)
    assert.is_true(second.generation > first.generation)
    assert.not_equal(first.a, second.a)
    assert.not_equal(first.b, second.b)
    assert.equal(first.generation, detaches[1].generation)
    local pending = view.ribbon.pending
    requests[1]()
    assert.equal(pending, view.ribbon.pending)

    actions.cycle_layout()
    wait_for(function()
      return view.cur_layout.name == "diff2_vertical"
    end)
    assert.is_false(api.nvim_win_is_valid(second.surface.win))
    assert.equal(native .. ",context:7", vim.o.diffopt)

    actions.cycle_layout()
    wait_for(function()
      return #attaches == 3
    end)
    vim.cmd("tabprevious")
    assert.is_false(api.nvim_win_is_valid(attaches[3].surface.win))
    assert.equal(native, vim.o.diffopt)
    local refreshed
    view.emitter:once("files_updated", function()
      refreshed = true
    end)
    vim.cmd("tabnext")
    wait_for(function()
      return #attaches == 4 and refreshed
    end)
    vim.cmd("set diffopt=internal,filler,vertical")
    wait_for(function()
      return view.cur_layout.gutter == nil
    end)
    vim.cmd("DiffviewClose")
    assert.equal("internal,filler,vertical", vim.o.diffopt)
  end)

  it("recovers from narrow views and leaves working native panes after dismissal", function()
    open()
    local first = attaches[1]
    api.nvim_win_set_width(view.panel.winid, vim.o.columns - 19)
    vim.cmd("redraw!")
    api.nvim_exec_autocmds("WinResized", { group = view.ribbon.group })
    wait_for(function()
      return view.cur_layout.gutter == nil
    end)
    assert.is_false(api.nvim_win_is_valid(first.surface.win))
    assert.equal(native .. ",context:7", vim.o.diffopt)

    api.nvim_win_set_width(view.panel.winid, 22)
    vim.cmd("redraw!")
    api.nvim_exec_autocmds("WinResized", { group = view.ribbon.group })
    wait_for(function()
      return #attaches == 2
    end)
    api.nvim_win_close(attaches[2].surface.win, true)
    wait_for(function()
      return view.cur_layout.gutter == nil
    end)
    assert.equal(native .. ",context:7", vim.o.diffopt)
    assert.is_true(view.cur_layout:is_valid())
  end)

  it("cleans a partial attach and restores the view profile when the adapter fails", function()
    local attach = adapter.attach
    adapter.attach = function(snapshot, request)
      attach(snapshot, request)
      error("fake renderer failure")
    end
    open()
    wait_for(function()
      return #detaches == 1 and view.cur_layout.gutter == nil
    end)
    assert.equal(0, #draws)
    assert.equal(native .. ",context:7", vim.o.diffopt)
    assert.is_true(view.cur_layout:is_valid())
    assert.equal(attaches[1].generation, detaches[1].generation)
  end)

  it("recreates the gutter after recovery of a closed source pane", function()
    open()
    local first = attaches[1]
    api.nvim_win_close(first.left, true)
    view:ensure_layout()
    wait_for(function()
      return #attaches == 2
    end)
    assert.is_false(api.nvim_win_is_valid(first.surface.win))
    assert.equal(view.cur_layout.a.id, attaches[2].left)
    assert.equal(view.cur_layout.b.id, attaches[2].right)
    assert.equal(first.a, attaches[2].a)
    assert.equal(first.b, attaches[2].b)
  end)
end)
