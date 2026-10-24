# Teak assessment for the Frame2D bake-off (zig-teak fallback, SPEC 15.6)

Assessed 2026-10-23 on the Snapdragon Windows 11 ARM64 laptop. Repo: teak, branch dev-hotschmoe, last commit 2026-07-15. Read-only; all builds were done in a copy under the session scratchpad.

## Verdict

**Ready with gaps.** Teak is a real, working, tested, agent-documented Zig UI framework that builds and runs on this machine (Windows ARM64, with a target workaround). It also targets Windows x64, Linux (X11 only) and the web (WebGPU through zunk). Its command-buffer model, native Win32 file dialogs, modal overlays, sliders, dropdowns and a virtualized list cover most of SPEC 5.5. The blockers for Frame2D are the canvas and the table. The canvas draws only polylines, rects and square markers, in canvas-local pixels, with no circles or transform, and the app rebuilds the whole primitive list every frame. There is no table or sortable-column widget, only a fixed-row-height virtual list that you compose into a table yourself. Pinch-zoom on web is not supported, and Teak needs Zig 0.16 while the bake-off targets 0.17. Expect roughly 1 to 2 agent-days of app-side work, plus possible Teak changes if the 200x200 render bench is too slow. It is a credible fallback, not a drop-in.

## Capability table

| Need | Status | Evidence |
|---|---|---|
| Arbitrary vector drawing (lines, polylines, filled shapes) | partial | `canvas` widget, `docs/features/canvas.md`. Primitives: `polyline`, `filled_rect`, `hline`, `vline`, `marker` (centered square). No circle, arc or filled polygon, and no world transform. Coordinates are canvas-local logical pixels, so the app does the pan/zoom math and rebuilds the slice every frame in the arena. |
| GPU batching | yes | Everything lowers to solid quads (a polyline segment becomes a rotated quad via `emitQuadCorners`) in one vertex buffer that grows dynamically (`src/gpu/wgpu_core.zig:645-652`). Frame-diff skips unchanged frames. The CPU vertex build per frame for ~80k members (several hundred thousand quads with moment diagrams) is the unmeasured risk. |
| Pan/zoom by mouse, wheel, trackpad | partial | `InputState` has `mouse_x/y`, `mouse_down/up`, `wheel_dx/dy` (`src/platform/host.zig:85-105`). Trackpad scroll arrives as wheel. Drag-to-pan needs the app to track press state across frames. Not verified end to end. |
| Pinch on web | no | `src/platform/wasm.zig:305-312`: zunk exposes only a single vertical `mouse.wheel` accumulator (no horizontal wheel, no touch, no ctrl flag). A Chromium trackpad pinch is a ctrl+wheel event, so it is lost at this layer. Needs a zunk/JS bridge change. |
| Virtualized list | yes | `push_virtual_list` (`src/core/cmd.zig:222-243`): fixed `item_extent`, `total_count`; the app emits only `visible_start..visible_end`. O(1) layout; sits inside `push_scroll`. |
| Sortable table, 20,100 rows | no (build it) | No table or sort code in `src` (grep). Compose from a header row of buttons, a sorted index array in the Model, and a virtual list of rows. Sorting 20,100 rows is trivial. No column resize. |
| Text quality | partial | Real glyph rasterization into an atlas (GDI/Segoe UI on Windows, stb_truetype + system TTF on Linux, browser on web). Rich-text spans exist. The glyph cache and per-frame text draws are capped at 256 (`src/gpu/glyph_cache.zig:23`, `wgpu_core.zig:65`), so a 30x9 table plus HUD is at the limit. Win32 DPI awareness is deferred (tasks.md), so text may look small or blurry on a scaled ARM display. |
| Buttons, checkbox, radio, slider, dropdown, text/numeric fields | yes | `llms.txt` ~160-210; `Dropdown(cap)`, `NumericField`, `TextField`. Slider is `slider(grab_msg, value)` plus `sliderDrag` (the app maps mouse x to value). |
| Modal dialog (Generate B x S) | yes | `cb.pushOverlay` with `modal = true`, `docs/cookbook.md` recipe 4. |
| File open/save dialogs | partial | `openFileDialog` / `saveFileDialog` on the Host; native `GetOpenFileNameW` on Win32 (`docs/features/functional-gaps.md` s.5). Not on X11. Web: async API exists but the JS bridge (`showOpenFilePicker`) is a pending zunk item. |
| Windows ARM64 | yes, with workaround | Built and ran here with `-Dtarget=aarch64-windows-gnu`; a wgpu-native aarch64-windows prebuilt is declared in `build.zig.zon`. README: the default target hits Zig issue Codeberg #31865. |
| Linux x86_64 / aarch64 | partial | X11 only (works under XWayland), libX11 dlopen'd, wgpu-native over Vulkan, needs a system TTF. Not tested here. |
| Windows x64 | yes (not tested) | Win32 + wgpu-native x86_64 prebuilt. |
| GPU backend | wgpu-native 25.0.2.2 | D3D12 on Windows, Vulkan on Linux (`src/gpu/wgpu_core.zig:322-323`), HighPerformance power preference. DLL/.so ships beside the exe. The adapter actually chosen on this machine was not recorded. |
| Web target | yes | `zig build web` via zunk (sibling path dep `../zunk`) writes `dist/` with wasm + `app.js` + `index.html`. WebGPU only, no WebGL fallback. counter_greeter: wasm 939,401 B (default optimize; ReleaseSmall not measured), app.js 14,817 B. Not loaded in a browser. |
| Per-frame solve in the loop | yes | `teak.run` calls `update`/`view` each frame, so a solve fits in `update` (UI thread). `Sub` timers give periodic messages. A worker thread is plain Zig on native; on wasm it is unlikely. |
| Frame timing / counters | no | No built-in frame_ms or perf HUD (grep `frame_ms`/`fps`; `src/core/debug_overlay.zig` is a layout debug overlay). The app must time `update`/`view` itself. True present-to-present time may need a custom loop instead of the closed `teak.run` wrapper. |
| Agent eyes | yes (strong) | `teak.snapshot` serializes Cmd + Rect to text (`tag (x,y,w,h) payload`, one line per cmd), pure and deterministic, used for golden tests. `TEAK_SNAPSHOT=<file>` makes `teak.run` mirror each changed frame (verified here). Canvas shows only `canvas (x,y,w,h) prims=N "label"`, so geometry is invisible to the snapshot. Also an a11y tree. |
| Docs for a cold agent | yes | `llms.txt` (522 lines, audit-enforced against `src/teak.zig`), `docs/consuming-teak.md`, `docs/cookbook.md` (~12 recipes), `docs/pitfalls.md`, `docs/HARDLINE.md`, per-feature contracts. Strict TEA with no widget state is a discipline the agent must follow. |

## Build and run results

Toolchain: `zig version` = **0.16.0** (patched ARM64 build at `C:\zig\aarch64-patched`; an x64 build is in `C:\zig\x86_64-prism`). No Zig 0.17 was found, so 0.17 compatibility is **untested**. Teak pins `.minimum_zig_version = "0.16.0"`. Builds ran from a copy in the scratchpad, with zunk copied beside it because `build.zig.zon` has `.zunk = .{ .path = "../zunk" }`. scc is not installed; lines were counted by hand.

| Step | Result |
|---|---|
| `zig build test` (repo root) | **222/222 tests passed**, 15/15 steps, about 19-23 s cold. The output also shows `skipping stbtt test: FontNotFound` and a "failed command" line that is stderr noise from a skipped Linux-font test (the summary reports success). |
| `examples/counter_greeter`: `zig build ui -Dtarget=aarch64-windows-gnu` | Built with no errors in about 23 s, producing `counter_greeter-ui.exe` and `wgpu_native.dll`. |
| Run it with `TEAK_SNAPSHOT=snap.txt`, 6 s | Window 884x461 stayed open until killed by `timeout` (rc 124, expected). `snap.txt` held the full widget tree. I did not inspect the screen, so rendering correctness and the GPU adapter are unverified. |
| `zig build web` (counter_greeter) | Succeeded in about 9 s. `dist/`: wasm 939,401 B, `app.js` 14,817 B, `index.html` 482 B. |
| `zig build ui` without the aarch64-windows-gnu flag | Not run (README documents a Zig 0.16 ARM64 crash). |

Codebase: about 47.8k lines of Zig (src, test, tools, examples; vendored and zig-pkg excluded), 131 commits since 2026-04-14, 221 `test` blocks, 3 examples (counter_greeter, todo, tree; none canvas-heavy or table-like). tasks.md has one open item (merge dev-hotschmoe to master) and deferred follow-ups: Win32 DPI, secondary windows on X11/wasm, dropdown scroll-to-reveal.

## Gaps and estimated work

| Gap | Work |
|---|---|
| Canvas lacks circles, polygons, transform; per-frame rebuild | App side: nodes as `marker` squares, supports as lines, own culling and world-to-screen math (about 0.5 day). If the 200x200 render bench is too slow, add a circle primitive or a retained, transformed draw list in Teak (about 1-2 days, requires a fork since the repo is read-only for this task). |
| No table widget | Header buttons + sort-index + `push_virtual_list` rows in `push_scroll` (about 0.5-1 day). |
| Frame timing | Wrap `update`/`view` with the monotonic clock and log solve_ms/frame_ms/lag_frames (about 0.5 day); a custom loop if present time is needed. |
| Pinch zoom on web | zunk/JS change to forward ctrl+wheel (about 0.5 day if zunk is editable); otherwise wheel plus +/- buttons. |
| File dialogs on Linux and web | Custom path-entry modal (about 0.5 day) or a JS file-input shim. |
| Text cap of 256 and DPI | Bump `glyph_cache.CAPACITY` (one line, but in Teak); check blur on the scaled display. |
| Zig 0.17 | Teak is on 0.16; a port is unknown effort (std churn). |
| zunk dependency | Sibling path dep; needs vendoring or pinning for reproducible builds. |

## Risks

- Zig version mismatch (0.16 vs the bake-off's 0.17): the `zig` stack would run an older toolchain, or Teak must be ported.
- The render bench (200x200, ~80k members, 600 frames, zoom to 8x) is untested; per-frame CPU rebuild of primitives and vertices with no culling or retained geometry may blow the budget.
- Frame-diff in `teak.run` skips unchanged frames, which can distort bench pacing; bench loops must force a change each frame.
- ARM64 Windows needs the `-Dtarget=aarch64-windows-gnu` workaround for a Zig compiler crash.
- Web is WebGPU only; headless Chromium without a GPU may fall back or fail (SPEC 15.3).
- Linux is X11 only; no native Wayland.
- Strict TEA/HARDLINE rules add friction for an agent used to retained-mode UIs, though the docs are good.
- Single-author project, `.version = "0.0.0"`, no API stability guarantee.

## Alternatives (not verified online; from prior knowledge, treat as unverified)

- **dvui**: SDL/raylib/web backends, tracks recent Zig, has scroll areas with virtual sizing and a grid widget, and path/polygon drawing. Its required Zig version and virtualized sortable table support are unconfirmed. SPEC 15.6 makes it the primary, so its smoke test comes first.
- **Dear ImGui via cimgui**: mature table API with sorting and clipper virtualization, a draw list with circles and polylines. It needs a C++ build and a per-platform renderer backend (including web), and it is not pure Zig.
