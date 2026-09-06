-- A sign column for jj workspaces, where gitsigns cannot go.
--
-- gitsigns needs a git repository to diff against. A SECONDARY jj workspace has
-- none and can never have one -- `jj git colocation enable` refuses outside the
-- main workspace -- so in a workspace tab the gutter is simply empty, and any
-- git tool that walks up from there describes the enclosing repo instead. This
-- plugin fills that gap and nothing more: in a colocated main workspace gitsigns
-- still works and should keep the gutter.
--
-- Two things it does NOT copy from gitsigns:
--   * Staging. jj has no index -- the working copy IS a commit -- so there is
--     nothing for "stage hunk" to mean. Squashing into the parent is the nearest
--     idea and belongs in the jj TUI, not in the gutter.
--   * Asking jj for the diff. `jj diff` snapshots the working copy, taking the
--     repo lock and writing an operation every time; run on every keystroke that
--     is a feedback loop through the greeter's op-log watcher. Instead the BASE
--     text is fetched once per revision (`jj file show`) and diffed against the
--     live buffer with vim.diff, which also means signs update as you type
--     rather than only on save.

local M = {}

local NS = vim.api.nvim_create_namespace("jjsigns")

M.opts = {
  -- Default base, as a revset. "@-" is the parent of the working copy, i.e.
  -- "changes I haven't committed", which is what HEAD means for gitsigns.
  base = "@-",
  signs = {
    add = { text = "┃" },
    change = { text = "┃" },
    delete = { text = "▁" },
    topdelete = { text = "▔" },
    changedelete = { text = "~" },
  },
  -- Redraw is debounced: a diff per keystroke is wasted work on a long file.
  debounce = 100,
  -- Only attach where gitsigns cannot, i.e. a workspace with no git repo above
  -- it. In a COLOCATED main workspace `@-` and git's HEAD are the same commit,
  -- so gitsigns already draws exactly this gutter there -- and it also does
  -- blame, which jj answers differently. Two gutters over one file would just
  -- fight. Set false to take over everywhere.
  only_without_git = true,
}

-- Highlight per hunk kind, linked to gitsigns' groups so the two backends are
-- indistinguishable in the gutter and follow the colorscheme together.
local HL = {
  add = "GitSignsAdd",
  change = "GitSignsChange",
  delete = "GitSignsDelete",
  topdelete = "GitSignsDelete",
  changedelete = "GitSignsChange",
}

---@type table<string, string> normalized workspace root -> base revset override
M.bases = {}

-- Inline diff view: removed lines as virtual lines, present lines tinted, and
-- word-level ranges within changed lines. The counterpart of gitsigns'
-- show_deleted + linehl + word_diff, which review mode toggles together. Global
-- like gitsigns', so it is a mode across all buffers rather than per window.
M.inline = false

-- Per-buffer state: { root, base, base_lines, hunks, timer }.
local state = {}

--- The jj workspace root containing a buffer's file, or nil. Unnamed buffers
--- deliberately resolve to nil rather than falling back to cwd -- a scratch
--- buffer belongs to no workspace. Nor does anything with a URI-style name
--- (term://, gh://, oil://...): vim.fs.root treats such a name as a relative
--- path and happily walks up from the cwd, which in a workspace tab IS a jj
--- root. A terminal gets its term:// name (BufFilePost) a moment before its
--- buftype is set, so the buftype guard in attach alone does not catch it.
---@param buf integer
---@return string?
function M.buf_root(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:match("^%w+://") then
    return nil
  end
  local root = vim.fs.root(name, ".jj")
  return root and vim.fs.normalize(root) or nil
end

--- The base revset a buffer diffs against: its workspace's override, else the
--- configured default.
---@param buf integer?
---@return string?
function M.base_for(buf)
  local root = M.buf_root(buf or 0)
  if not root then
    return nil
  end
  return M.bases[root] or M.opts.base
end

--- Set (or with nil, clear) the review base for one workspace and redraw its
--- loaded buffers. The counterpart of gitsigns' change_base, and the reason this
--- plugin exists rather than a simpler one: review mode re-bases the gutter onto
--- the branch's merge point at runtime.
---@param base string? revset, nil to restore the default
---@param root string? normalized workspace root (default: the cwd's)
function M.change_base(base, root)
  root = root and vim.fs.normalize(root) or M.buf_root(0)
  if not root then
    return
  end
  M.bases[root] = base
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if state[buf] and state[buf].root == root then
      state[buf].base_lines = nil -- force a refetch at the new revision
      M.refresh(buf)
    end
  end
end

--- Fetch `path`'s content at `base`, as lines. Async; `cb` gets nil when the
--- file doesn't exist there (a newly added file, which is then all-additions).
---@param root string
---@param base string
---@param path string absolute
---@param cb fun(lines: string[]?)
local function base_lines(root, base, path, cb)
  local rel = path:sub(#root + 2)
  vim.system(
    -- --ignore-working-copy: this must not snapshot. The content at a committed
    -- revision cannot change under us, so there is nothing to be stale about.
    { "jj", "file", "show", "--ignore-working-copy", "--color=never", "-r", base, "--", rel },
    { cwd = root, text = true },
    vim.schedule_wrap(function(out)
      if out.code ~= 0 then
        return cb(nil)
      end
      local lines = vim.split(out.stdout or "", "\n")
      -- A file's trailing newline makes split() yield one empty element that
      -- the buffer has no counterpart for; left in, every file grows a phantom
      -- hunk on the line past its end.
      if lines[#lines] == "" then
        table.remove(lines)
      end
      cb(lines)
    end)
  )
end

--- Redraw `buf`'s signs from its current text.
---@param buf integer
function M.refresh(buf)
  local st = state[buf]
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local function draw(base)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local indices = vim.diff(table.concat(base, "\n"), table.concat(lines, "\n"), {
      result_type = "indices",
    }) or {}
    st.hunks = require("jjsigns.diff").from_indices(indices, base, lines)
    M.render(buf)
  end

  if st.base_lines then
    return draw(st.base_lines)
  end
  base_lines(st.root, M.base_for(buf) or M.opts.base, vim.api.nvim_buf_get_name(buf), function(got)
    if not state[buf] then
      return
    end
    -- A file that doesn't exist at the base is entirely new: diffing against
    -- nothing marks every line added, which is what it is.
    st.base_lines = got or { "" }
    draw(st.base_lines)
  end)
end

--- Paint `buf`'s hunks into the sign column (and, with the inline view on, into
--- the buffer itself).
---@param buf integer
function M.render(buf)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  -- A buffer that became special after attaching (buftype is set late for some
  -- kinds) is not ours to paint; let go of it.
  if vim.bo[buf].buftype ~= "" then
    state[buf] = nil
    return
  end
  local last = vim.api.nvim_buf_line_count(buf)
  if M.inline then
    for _, m in ipairs(require("jjsigns.diff").inline_marks(state[buf].hunks or {}, last)) do
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, m.row, m.col or 0, m.opts)
    end
  end
  for _, h in ipairs(state[buf].hunks or {}) do
    local sign = M.opts.signs[h.type]
    -- A deletion covers no lines, so it still needs one row to sit on.
    for row = h.start, h.start + math.max(h.count, 1) - 1 do
      if row >= 1 and row <= last then
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, row - 1, 0, {
          sign_text = sign.text,
          sign_hl_group = HL[h.type],
          priority = 6,
        })
      end
    end
  end
end

--- Queue a refresh, debounced per buffer.
---@param buf integer
local function queue(buf)
  local st = state[buf]
  if not st then
    return
  end
  if st.timer and not st.timer:is_closing() then
    st.timer:stop()
    st.timer:close()
  end
  st.timer = vim.defer_fn(function()
    st.timer = nil
    M.refresh(buf)
  end, M.opts.debounce)
end

--- Start following `buf`, if it is a file in a jj workspace.
---@param buf integer
function M.attach(buf)
  if state[buf] or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return
  end
  local root = M.buf_root(buf)
  if not root then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if M.opts.only_without_git and vim.fs.root(name, ".git") then
    return
  end
  state[buf] = { root = root, hunks = {} }
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if not state[buf] then
        return true -- detach
      end
      vim.schedule(function()
        queue(buf)
      end)
    end,
    on_detach = function()
      state[buf] = nil
    end,
  })
  M.refresh(buf)
end

--- The hunk under the cursor, if any.
---@return JJHunk?
local function current_hunk()
  local buf = vim.api.nvim_get_current_buf()
  local st = state[buf]
  return st and require("jjsigns.diff").at(st.hunks or {}, vim.fn.line("."))
end

--- Show the hunk under the cursor in a float, base version above working copy.
function M.preview_hunk()
  local h = current_hunk()
  if not h then
    return vim.notify("jjsigns: no hunk here", vim.log.levels.INFO)
  end
  local lines = {}
  for _, l in ipairs(h.old) do
    lines[#lines + 1] = "-" .. l
  end
  for _, l in ipairs(h.new) do
    lines[#lines + 1] = "+" .. l
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "diff"
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.max(math.min(width + 1, vim.o.columns - 10), 20),
    height = math.max(#lines, 1),
    style = "minimal",
    border = "rounded",
  })
end

--- Turn the inline diff view on or off (toggle when `on` is nil) and repaint
--- every attached buffer.
---@param on boolean?
function M.toggle_inline(on)
  if on == nil then
    on = not M.inline
  end
  M.inline = on
  for buf in pairs(state) do
    if vim.api.nvim_buf_is_valid(buf) then
      M.render(buf)
    end
  end
end

--- Jump to the next (or previous) hunk, wrapping.
---@param backwards? boolean
function M.next_hunk(backwards)
  local buf = vim.api.nvim_get_current_buf()
  local st = state[buf]
  local h = st and require("jjsigns.diff").next(st.hunks or {}, vim.fn.line("."), backwards)
  if h then
    vim.api.nvim_win_set_cursor(0, { math.min(h.start, vim.api.nvim_buf_line_count(buf)), 0 })
  end
end

--- Restore the hunk under the cursor to its base content.
---
--- Done in the buffer rather than with `jj restore`, which only works whole-file
--- and would throw away the rest of your edits along with this hunk.
function M.reset_hunk()
  local h = current_hunk()
  if not h then
    return vim.notify("jjsigns: no hunk here", vim.log.levels.INFO)
  end
  local first = h.start - 1
  local last = h.count == 0 and first or (first + h.count)
  -- A deletion has nothing in the buffer to replace, so its base lines go back
  -- in after the line the sign sits on.
  local at = h.count == 0 and h.start or first
  vim.api.nvim_buf_set_lines(0, h.count == 0 and at or first, last, false, h.old)
end

--- Wire up the autocmds. Safe to call more than once.
---@param opts table?
function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
  -- Inline-view groups, under gitsigns' names so one colorscheme (or override)
  -- styles both gutters. `default`: never clobber what gitsigns or the user set.
  for group, link in pairs({
    GitSignsAddLn = "DiffAdd",
    GitSignsChangeLn = "DiffChange",
    GitSignsDeleteVirtLn = "DiffDelete",
    GitSignsAddInline = "TermCursor",
    GitSignsChangeInline = "TermCursor",
    GitSignsDeleteInline = "TermCursor",
  }) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  local group = vim.api.nvim_create_augroup("jjsigns", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufFilePost" }, {
    group = group,
    callback = function(args)
      M.attach(args.buf)
    end,
  })
  -- A write can move the working copy (an auto-snapshot elsewhere, a jj command
  -- in the side terminal), so the base may no longer be what we cached.
  vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
    group = group,
    callback = function(args)
      local st = state[args.buf]
      if st then
        st.base_lines = nil
        queue(args.buf)
      end
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.attach(buf)
    end
  end
end

return M
