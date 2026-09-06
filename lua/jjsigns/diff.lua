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

return M
