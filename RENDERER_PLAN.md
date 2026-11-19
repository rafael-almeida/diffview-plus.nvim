# Renderer plan for Diffview+ and Ribbonview

This live document tracks the implementation against Diffview+ base `fae72d6c981075dce2e0f946f002382ce0cb44e1`. Update the status and verification notes below when changing either integration.

## Implementation progress

- [x] Reproduce normal-split navigation and resizing on Neovim 0.12.0.
- [x] Add the opt-in gutter, scoped focus handling, and narrow-window fallback.
- [x] Publish committed comparisons with generation-scoped redraws.
- [x] Integrate filler-free mode with the existing `diffopt` owner.
- [x] Connect the Ribbonview canvas and native source underlines to the gutter.
- [x] Verify lifecycle and failure recovery with a fake adapter, and exercise both rendering backends.
- [x] Measure scrolling in headless Neovim and in Kitty.
- [x] Record the full-suite results and the cached file-switch benchmark.

### Findings and decisions

- Neovim 0.12.0 accepts `focusable=false` and `mouse=false` on a normal split. Directional and cyclic window commands can still enter it. Redirect focus only when the gutter is still current after the command finishes. Immediate redirection also interrupted a multi-window command during the prototype. Keep Diffview+'s own window enumeration limited to the source panes.
- `wincmd =` can change the width of a `winfixwidth` split. Reconcile its width on a window resize and recheck whether the two source panes still fit.
- The first full baseline test run on Neovim 0.12.0 reported ten failures across the jj and Mercurial suites. Keep the output for comparison with the post-change run.
- `view.ribbon` takes an adapter and defaults to `false`. Ribbonview supplies `diffview_adapter()`. Opted-in views skip Ribbonview's standalone overlay discovery even when the host falls back to the native layout.
- Keep the split and the active diff profile across same-layout file switches. Detach marks and images before changing either source, then publish the final comparison after the file switch worker drains. Use the scheduled comparison generation to drop callbacks from earlier files.
- A deliberate external `diffopt` write replaces the whole option baseline and pauses the gutter until tab reentry or `require('ribbonview').refresh()`. Normal layout switches restore the regular view profile.
- The first headless smoke run verified the dedicated cell canvas, native diff modes, `wincmd =` recovery, tab leave and reentry, runtime enable and disable, and option restoration on close.
- Compute the minimum from each source pane's measured status-column width, 12 text columns per pane, and the editor's `winminwidth`. Include the requested gutter and both separators. Widening the comparison above that threshold makes the gutter eligible again.
- Draw only in the intersection of the two source text areas and the gutter. An offset in the snapshot accounts for source winbars. The scratch buffer stays in the horizontal layout, outside its source-window list. The host uses window redraw notifications for folds because a native fold toggle can change the visible row range without a `WinScrolled` event.
- The host accepts a real one-sided Git comparison even though Diffview+ turns native diff mode off in the empty window. It waits for a committed pair with the expected buffers, including the empty side.

### Verification

- Fake adapter checks cover atomic file updates, stale requests, cursor navigation, resize, `:diffget` and undo, vertical layout switches, tab leave and reentry, external option ownership, deliberate dismissal, partial attach failure, and recovery after a source pane closes. [Host tests](lua/diffview/tests/functional/ribbon_spec.lua)
- Cross-plugin checks cover the native left insertion and right deletion underlines, preserved fold and custom status columns, winbar offsets, enable and disable, staging and unstaging, file history, and whole-file additions and deletions. Viewport and Kitty upload unit checks pass alongside the upstream overlay integration test. [Ribbonview tests](../ribbonview.nvim/tests)
- Kitty 0.45 in Xvfb drew the image and both underlines. Opening the top fold moved the changes out of view and cleared the image without a scroll event. The 110-column terminal restored the six-column gutter after shrinking to 54 columns and expanding again. A click in the gutter moved focus to a source pane. Using Ctrl-W and a direction key crossed the gutter.
- `make test` passed on Neovim 0.10.4 and 0.12.2 after adding jj and Mercurial to the test environment. The Perforce integration cases were skipped because `p4` and `p4d` were absent. The schema, LuaLS, and StyLua checks passed.

### Scroll benchmark

Neovim 0.12.0, 12,000-line dense Git fixture, 80-column headless editor with the file panel closed, six-column ribbons, identical filler-free options. Process CPU over 120 steps spaced 8 ms apart, median of three runs. Kitty transport was stubbed for these timings and payload counts.

| Renderer | Synchronized CPU | Independent CPU | Independent Kitty upload bytes |
| --- | ---: | ---: | ---: |
| Native Diffview+ | 146 ms | 149 ms | |
| Overlay cells | 233 ms | 249 ms | |
| Dedicated cells | 236 ms | 235 ms | |
| Overlay Kitty | 246 ms | 285 ms | 4.99 MB |
| Dedicated Kitty | 254 ms | 288 ms | 6.96 MB |

The dedicated path drew about 60 frames per replay. The overlay drew about 43. That cadence accounted for the higher upload total. For 30 individual scroll steps in a 110-column Kitty window, the two paths each uploaded 29 images and sent 4.98 MB. Measured from issuing an RPC command to seeing gutter pixels change via X11, median latency was 36.4 ms for the overlay and 36.6 ms for the dedicated gutter. This includes RPC startup, display polling, and the software-rendered terminal.

### Cached file switching

Headless Neovim 0.12.0, eight 12,000-line files and the same filler-free profile. Each file was opened once before measuring process CPU over 24 switches. Median of three runs, with Kitty transport stubbed.

| Renderer | CPU |
| --- | ---: |
| Native Diffview+ | 1,812 ms |
| Overlay cells | 2,594 ms |
| Dedicated cells | 2,235 ms |
| Overlay Kitty | 2,713 ms |
| Dedicated Kitty | 2,493 ms |

## Design and scope

Diffview+ should own the gutter, the source panes, and the lifecycle of each active comparison. Ribbonview should own the visuals inside that gutter and the insertion and deletion underlines in the source panes. Neovim should continue to compute and display native diffs and handle hunk commands, folding, and editing. This keeps the project focused on layout and rendering integration and preserves the Git workflows that already work.

| Area | Owner | Proposed behavior |
| --- | --- | --- |
| Git, buffers, and native actions | Diffview+ and Neovim | Use existing revisions, staging, history, highlighting, folds, hunk jumps, `:diffget`, and `:diffput`. |
| Center gutter | Diffview+ | Reserve an auxiliary window between the source panes and expose its actual drawable area. |
| Comparison lifecycle | Diffview+ | Tell the renderer when a file is ready, when the gutter or viewport changes, and when the comparison is being replaced or closed. |
| Connector rendering | Ribbonview | Reuse the existing viewport projection, cells, Kitty rasterization, image cache, and the thin underline on the empty side of a hunk. |
| Options for filler rows | Diffview+ | Extend its existing `diffopt` lifecycle so the active view has one owner for global option changes. |

Start with `diff2_horizontal` when the user opts in. Apply the same contract to two-way file history when it uses that layout. Keep existing layouts for vertical comparisons, inline and raw views, multiway merges, and the worktree overview. Preserve Diffview+'s current Neovim 0.10 minimum for the ordinary view. The first Ribbonview adapter can require Neovim 0.12, which matches its current support and Kitty's `nvim_ui_send()` requirement. [Diffview+ requirements](README.md) · [Ribbonview setup](../ribbonview.nvim/README.md)

## Where to integrate

| Existing code | Rework |
| --- | --- |
| [Horizontal layout](lua/diffview/scene/layouts/diff_2_hor.lua) and [common layout](lua/diffview/scene/layout.lua) | Create and recover the optional gutter alongside the two source windows. Keep the gutter separate from `Layout.windows` and `symbols`, since file loading, diff operations, and scroll binding iterate those source windows. |
| [Standard view](lua/diffview/scene/views/standard/standard_view.lua) | Attach to the committed layout. This fork already stages layout changes, publishes the new layout after creation, and coalesces rapid file selection. Preserve those ordering guarantees. |
| [View lifecycle and diff options](lua/diffview/scene/view.lua) | Compose the ribbon profile with the view's existing `diffopt` overrides. Reuse entry, exit, and close handling. |
| [Inline layout](lua/diffview/scene/layouts/diff_1_inline.lua) | Follow the existing render generation and teardown practice for invalidating delayed work. Inline rendering stays a separate layout. |
| [Ribbonview discovery](../ribbonview.nvim/lua/ribbonview/diffview.lua) and [fold-column lane](../ribbonview.nvim/lua/ribbonview/lane.lua) | Replace discovery and fold-column management through the new Diffview+ adapter. Keep the existing integration path available for users of upstream Diffview. |

### Dedicated gutter

Add an auxiliary scratch split to the horizontal layout. Give it a requested width and measure the width and height Neovim actually grants. It should have no Git file, window-local diff mode, scroll binding, or cursor binding. Keep it out of file enumeration, hunk targets, `view_windo`, and pane layout loops such as scroll synchronization. The normal source panes should retain their native status columns, signs, and fold controls. [Layout file loading and recovery](lua/diffview/scene/layout.lua) · [Window actions](lua/diffview/actions.lua)

Validate keyboard and mouse behavior early. Neovim normal splits can take focus, so a scratch split alone cannot promise the focus behavior of the old float. Test pane movement, file panel toggles, direct clicks, `:close`, resize, and `wincmd =`. Handle focus and recovery within the opted-in layout and avoid intercepting global navigation commands. Confirm the gutter can close cleanly and collapse to ordinary Diffview when the view is too narrow or the renderer is unavailable. The native layout must remain usable if gutter allocation fails.

Test the two split separators and the edge near the right pane's status column in an actual terminal. The renderer needs a clear boundary for each ribbon tip and enough usable width for the curve. Keep the current thin underlines attached to source rows and align the Kitty tips with them. Include wrapped lines, closed folds, line numbers, custom status columns, and winbars when calculating the common drawable rows. A gap at the very start of a file has no real preceding row to underline.

### Renderer contract and lifecycle

Define a small optional Lua adapter. Its exact configuration name can follow the fork's conventions. A renderer declares whether it can attach to a comparison, attaches to an already committed surface, receives invalidations, and detaches. Diffview+ should run without loading Ribbonview when the gutter is disabled. Ribbonview's own setup remains the place for backend selection and graphics settings.

Pass a snapshot containing the view or tab identity, a comparison generation, left and right window and buffer IDs, the gutter window and buffer IDs, and the drawable row range. Give the renderer the effective diff options or a documented way to read them. Expose IDs and dimensions through this contract so Ribbonview no longer needs to read live layout internals or guess which windows belong to a diff.

- **Attach** after the layout has been published and its file windows are ready. `Layout.open_files()` can also emit `files_opened` for temporary null content. Distinguish that path from a real one-sided Git comparison, where one source can legitimately be empty.
- **Update** after a same-layout file switch has finished. Publish both new buffer IDs together. Ignore updates from staged layouts, discarded requests, or stale callbacks after a yield.
- **Invalidate** on resize, scroll, folds, colorscheme changes, and relevant edits. Keep scroll notifications cheap. Coalesce them in one place and read the latest viewport when drawing. Keep Git loading and layout transitions outside the frame callback.
- **Detach** before releasing a gutter or source window, and on tab leave, unsupported layout, or renderer failure. Invalidate pending work and release images, decorations, timers, and buffers owned by the renderer. Make cleanup safe after a partial attach or a second detach.

Use a native layout fallback if an adapter errors. Renderer failure should never interrupt Diffview+'s async file swap or trigger recovery against the wrong tab. Add a fake renderer to the fork's tests so lifecycle and failure behavior can be tested without Kitty or Ribbonview installed. [Staged layout and cancellation paths](lua/diffview/scene/views/standard/standard_view.lua) · [Existing renderer teardown](lua/diffview/scene/layouts/diff_1_inline.lua)

### Native diff options and source behavior

Diffview+ already applies and restores its configured `diffopt` overrides in the view lifecycle. Extend that path instead of running a second option manager from the Ribbonview adapter. When a committed, supported ribbon view is active, compose the profile after the view's regular overrides and remove `filler` and all `linematch:*` entries. Neovim's `linematch` enables filler implicitly, so `filler = false` alone is insufficient. On a switch back to a native layout within the same tab, restore the regular Diffview+ profile. On tab leave or close, restore the user's prior options. [Current option owner](lua/diffview/scene/view.lua) · [Filler verification](../ribbonview.nvim/IMPLEMENTATION.md)

The active gutter tracks the applied string and restores the regular view profile only while that value still matches. An explicit external write supplies the next baseline and dismisses the gutter for the current tab visit. Global `diffopt` still affects every diff window while the active view changes it. Removing `linematch` can change alignment and native hunk boundaries.

The adapter can keep Ribbonview's current cached visual hunks. Native Neovim remains the authority for editing and hunk operations. Validate compatibility with supported diff flags, whitespace options, and whole-file additions and deletions. If the renderer cannot match a custom diff expression or anchored comparison, use the native view. A new diff engine or Neovim core patch is outside this plan. [Current visual hunk calculation](../ribbonview.nvim/lua/ribbonview/hunks.lua) · [Native hunk actions](lua/diffview/actions.lua)

### Canvas and performance

Make the Ribbonview canvas target injectable. For the new integration, draw cell ribbons or Kitty placeholders into the supplied gutter scratch buffer. Diffview+ owns the surrounding split and geometry, while Ribbonview owns marks and images written to that surface. Reuse Ribbonview's existing scroll coalescing, crop, span rasterizer, and image translation when both panes move together. Keep ordinary redraws on their current path when the feature is disabled.

The dedicated gutter should remove the fold-column workaround and repeated window discovery. It still uses Kitty images for smooth curves and incurs a rasterization and upload when the shape changes. Judge runtime improvements with measurements. Compare plain Diffview+, the existing addon path, and the integrated path using the same layout width, fixture, and `diffopt` profile. Collect headless CPU for file switches and scrolling, and measure real terminal frame latency and bytes sent for Kitty. Run both synchronized and independent scrolling, including ribbons entering and leaving view. [Existing benchmark methodology](../ribbonview.nvim/IMPLEMENTATION.md)

## Implementation sequence

| Phase | Deliverable | Evidence for review |
| --- | --- | --- |
| 1. Gutter feasibility | Optional blank scratch gutter in the horizontal layout. | Two source windows stay valid and native. Focus, resizing, panel toggles, recovery, and narrow-window collapse work in an interactive session. |
| 2. Renderer lifecycle | Adapter contract with a fake renderer and generation guards. | Same-layout switches, staged swaps, rapid navigation, tab changes, and renderer failures produce deterministic attach and detach behavior. |
| 3. Diff options | Filler-free mode through the fork's existing option owner. | Filler rows disappear, regular layouts retain their profile, `diffopt` restores on every exit path, and user changes survive. |
| 4. Ribbonview adapter | Render into the supplied gutter with cells first, then Kitty. | Changes and underlines align with the source rows. Native fold controls and custom status columns work. Images and decorations clear on switches and close. |
| 5. Regression and performance | Exercise existing views and compare before and after profiles. | Native Git and diff operations pass. Headless and real-terminal results show what the integration changes. Document the feature, option behavior, and fallback. |

## Open issues and follow-up

- Neovim still sees the gutter as a real split during global window commands such as `:windo`. Focus returns to a source pane when a command finishes in the gutter. Diffview+'s window actions continue to visit only source panes.
- Both split separators are visible in Kitty. Themes with a high-contrast separator make the gap between the source underline and its ribbon tip more visible.
- The higher redraw cadence increases Kitty traffic on continuous scroll. If that becomes a bottleneck, compare bandwidth at equal frame rates before changing the rasterizer.
- The initial adapter contract is documented through the Ribbonview configuration. Compatibility for independently developed adapters is undecided. Layouts other than `diff2_horizontal`, including pinned file history, use the native view.
- The legacy overlay still expects both source windows to be in diff mode. Whole-file changes in Diffview+ use the dedicated adapter because the fork disables diff mode on the empty side.
