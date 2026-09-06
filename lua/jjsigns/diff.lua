-- Hunk shaping: the pure half of jjsigns.
--
-- The diff itself is `vim.diff` over two in-memory texts, not `jj diff`. That is
-- deliberate: asking jj for the diff would make it snapshot the working copy on
-- every keystroke -- taking the repo lock and writing a new operation each time,
-- which the greeter's watcher then reacts to by asking for another report. One
-- `jj file show` per base change, diffed in-process, gives live signs while you
-- type (before saving, as gitsigns does) and touches the repo exactly never.
--
-- Kept apart from init.lua because this is the part worth testing: everything
-- else is extmarks and process plumbing, and a hunk classified wrongly is a
-- sign column that quietly lies about which lines changed.

local M = {}

---@class JJHunk
---@field type "add"|"change"|"delete"|"changedelete"|"topdelete"
---@field start integer first buffer line the sign applies to (1-based)
---@field count integer buffer lines covered (0 for a pure deletion)
---@field old string[] the base's version of the lines (for preview and reset)
---@field new string[] the working copy's version

--- Classify one hunk from the counts either side.
---
--- A pure deletion has no line of its own to sit on, so it marks the line ABOVE
--- the cut -- except when the cut is at the very top of the file, where there is
--- no line above and the sign goes on line 1 as a "topdelete" instead. This is
--- the same convention gitsigns uses, so the gutter reads identically whichever
--- backend drew it.
---@param old_start integer first line the hunk removes, on the base side
---@param old_count integer lines the base had here
---@param new_count integer lines the working copy has here
---@return "add"|"change"|"delete"|"changedelete"|"topdelete"
function M.classify(old_start, old_count, new_count)
  if old_count == 0 then
    return "add"
  end
  if new_count == 0 then
    return old_start <= 1 and "topdelete" or "delete"
  end
  return old_count > new_count and "changedelete" or "change"
end

--- Shape `vim.diff`'s index tuples into hunks, carrying the text either side.
---
--- vim.diff (result_type "indices") yields {start_a, count_a, start_b, count_b},
--- 1-based, where a count of 0 means "nothing on this side" and the matching
--- start points at the line BEFORE the gap.
---@param indices integer[][] as returned by vim.diff
---@param old_lines string[] the base's lines
---@param new_lines string[] the buffer's lines
---@return JJHunk[]
function M.from_indices(indices, old_lines, new_lines)
  local hunks = {}
  for _, idx in ipairs(indices) do
    local sa, ca, sb, cb = idx[1], idx[2], idx[3], idx[4]
    local old, new = {}, {}
    for i = sa, sa + ca - 1 do
      old[#old + 1] = old_lines[i]
    end
    for i = sb, sb + cb - 1 do
      new[#new + 1] = new_lines[i]
    end
    hunks[#hunks + 1] = {
      type = M.classify(sa, ca, cb),
      -- A deletion has no line of its own: vim.diff points sb at the line above
      -- the gap, which is where the sign goes (line 1 when the cut is at the
      -- very top, where there is no line above).
      start = cb == 0 and math.max(sb, 1) or sb,
      count = cb,
      old = old,
      new = new,
    }
  end
  return hunks
end

--- The hunk containing (or nearest below) `lnum`, for preview/reset.
---@param hunks JJHunk[]
---@param lnum integer 1-based buffer line
---@return JJHunk?
function M.at(hunks, lnum)
  for _, h in ipairs(hunks) do
    local last = h.start + math.max(h.count, 1) - 1
    if lnum >= h.start and lnum <= last then
      return h
    end
  end
  return nil
end

--- The next hunk strictly after `lnum`, wrapping to the first.
---@param hunks JJHunk[]
---@param lnum integer
---@param backwards? boolean
---@return JJHunk?
function M.next(hunks, lnum, backwards)
  if #hunks == 0 then
    return nil
  end
  if backwards then
    local prev
    for _, h in ipairs(hunks) do
      if h.start < lnum then
        prev = h
      end
    end
    return prev or hunks[#hunks]
  end
  for _, h in ipairs(hunks) do
    if h.start > lnum then
      return h
    end
  end
  return hunks[1]
end

--- Split a line into tokens for word-level diffing: runs of word characters,
--- runs of whitespace, and single other characters. Whitespace stays a token so
--- a change to indentation still shows, but as its own range.
---@param line string
---@return string[]
local function tokens(line)
  local out = {}
  local i = 1
  while i <= #line do
    local w = line:match("^%w+", i) or line:match("^%s+", i) or line:sub(i, i)
    out[#out + 1] = w
    i = i + #w
  end
  return out
end

---@class JJRange
---@field [1] integer 0-based start byte column
---@field [2] integer 0-based exclusive end byte column

--- Word-level differences between one base line and its working-copy pairing.
--- Tokens are diffed as if they were lines, so vim.diff does the alignment; the
--- token indices then map back to byte columns. Returns the changed ranges on
--- either side.
---@param old string
---@param new string
---@return JJRange[] old_ranges, JJRange[] new_ranges
function M.word_ranges(old, new)
  local ot, nt = tokens(old), tokens(new)
  local idx = vim.diff(table.concat(ot, "\n"), table.concat(nt, "\n"), { result_type = "indices" })
    or {}
  --- Byte offset where token `n` (1-based) starts; #toks+1 gives the line end.
  local function offsets(toks)
    local off, at = {}, 0
    for n, t in ipairs(toks) do
      off[n] = at
      at = at + #t
    end
    off[#toks + 1] = at
    return off
  end
  local oo, no = offsets(ot), offsets(nt)
  local old_r, new_r = {}, {}
  for _, h in ipairs(idx) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca > 0 then
      old_r[#old_r + 1] = { oo[sa], oo[sa + ca] }
    end
    if cb > 0 then
      new_r[#new_r + 1] = { no[sb], no[sb + cb] }
    end
  end
  return old_r, new_r
end

---@class JJMark
---@field row integer 0-based buffer row the extmark sits on
---@field opts table nvim_buf_set_extmark options

--- Highlight groups for the inline view. gitsigns' names, so a colorscheme (or
--- triage's overrides) styles both backends at once.
M.hl = {
  add_ln = "GitSignsAddLn",
  change_ln = "GitSignsChangeLn",
  add_inline = "GitSignsAddInline",
  change_inline = "GitSignsChangeInline",
  delete_inline = "GitSignsDeleteInline",
  delete_virt = "GitSignsDeleteVirtLn",
}

--- A removed line rendered as virtual-text chunks: the whole line in the
--- deleted-line colour, with word-level ranges (if given) in the stronger
--- inline colour.
---@param line string
---@param ranges JJRange[]?
---@return table[] chunks {text, hl}
local function virt_chunks(line, ranges)
  local chunks, at = {}, 0
  for _, r in ipairs(ranges or {}) do
    if r[1] > at then
      chunks[#chunks + 1] = { line:sub(at + 1, r[1]), M.hl.delete_virt }
    end
    chunks[#chunks + 1] = { line:sub(r[1] + 1, r[2]), M.hl.delete_inline }
    at = r[2]
  end
  if at < #line or #chunks == 0 then
    chunks[#chunks + 1] = { line:sub(at + 1), M.hl.delete_virt }
  end
  return chunks
end

-- Below the signs' priority (6 in init.lua): an extmark carrying line_hl_group
-- or virt_lines counts as a sign and competes for the sign-column slot, and the
-- winner draws its text there. A tint mark that won would leave the slot blank.
-- Word marks (hl_group only) take no slot, and sit above the tint, treesitter
-- (100) and LSP semantic tokens (125) so a syntax background cannot bury them.
local TINT_PRIORITY = 5
local WORD_PRIORITY = 200

--- The extmarks that draw the inline diff for a set of hunks: gitsigns'
--- show_deleted + linehl + word_diff in one pass. Removed lines appear as
--- virtual lines where they used to be (above the hunk for changes and
--- top-of-file cuts, below the sign line for other deletions); present lines
--- are tinted whole, and within a changed line only the words that differ get
--- the stronger inline colour. Pure, so the mapping is testable without a
--- buffer.
---@param hunks JJHunk[]
---@param line_count integer buffer lines, to clip marks a stale hunk may overrun
---@return JJMark[]
function M.inline_marks(hunks, line_count)
  local marks = {}
  for _, h in ipairs(hunks) do
    local is_change = h.type == "change" or h.type == "changedelete"
    -- Pair the i-th removed line with the i-th present one for word diffing.
    local old_ranges = {}
    if is_change then
      for i = 1, math.min(#h.old, #h.new) do
        local o_r, n_r = M.word_ranges(h.old[i], h.new[i])
        old_ranges[i] = o_r
        local row = h.start + i - 2
        for _, r in ipairs(n_r) do
          if row < line_count and r[2] > r[1] then
            marks[#marks + 1] = {
              row = row,
              opts = { end_col = r[2], hl_group = M.hl.change_inline, priority = WORD_PRIORITY },
              col = r[1],
            }
          end
        end
      end
    end
    -- Whole-line tint for lines that exist in the buffer.
    for i = 0, h.count - 1 do
      local row = h.start + i - 1
      if row < line_count then
        marks[#marks + 1] = {
          row = row,
          opts = {
            line_hl_group = h.type == "add" and M.hl.add_ln or M.hl.change_ln,
            priority = TINT_PRIORITY,
          },
        }
      end
    end
    -- Removed lines as virtual lines.
    if #h.old > 0 then
      local virt = {}
      for i, line in ipairs(h.old) do
        virt[#virt + 1] = virt_chunks(line, old_ranges[i])
      end
      local above = is_change or h.type == "topdelete"
      local row = math.min(h.start - 1, line_count - 1)
      if row >= 0 then
        marks[#marks + 1] = {
          row = row,
          opts = { virt_lines = virt, virt_lines_above = above, priority = TINT_PRIORITY },
        }
      end
    end
  end
  return marks
end

return M
