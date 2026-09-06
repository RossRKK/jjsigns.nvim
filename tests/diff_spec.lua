-- Hunk parsing and classification. The sign column is drawn straight off these,
-- so a misread header is a gutter that lies about which lines changed.

local assert = require("luassert")
local diff = require("jjsigns.diff")

describe("diff.classify", function()
  it("calls a hunk with nothing on the base side an addition", function()
    assert.equals("add", diff.classify(0, 0, 3))
  end)

  it("calls a hunk with nothing on the new side a deletion", function()
    assert.equals("delete", diff.classify(5, 3, 0))
  end)

  -- A cut at the top of the file has no line above to hang the sign on.
  it("marks a deletion at the top of the file as topdelete", function()
    assert.equals("topdelete", diff.classify(1, 2, 0))
  end)

  it("distinguishes a change that also loses lines", function()
    assert.equals("change", diff.classify(4, 2, 2))
    assert.equals("change", diff.classify(4, 2, 5))
    assert.equals("changedelete", diff.classify(4, 5, 2))
  end)
end)

describe("diff.from_indices", function()
  --- Diff two texts the way init.lua does, then shape the result.
  local function hunks(a, b)
    local al, bl = vim.split(a, "\n"), vim.split(b, "\n")
    return diff.from_indices(vim.diff(a, b, { result_type = "indices" }), al, bl)
  end

  it("reads an addition, keeping the added lines", function()
    local h = hunks("b\nc\n", "a\nb\nc\n")
    assert.equals(1, #h)
    assert.equals("add", h[1].type)
    assert.equals(1, h[1].start)
    assert.equals(1, h[1].count)
    assert.same({ "a" }, h[1].new)
    assert.same({}, h[1].old)
  end)

  it("keeps both sides of a change, for preview and reset", function()
    local h = hunks("a\nb\n", "a\nX\n")
    assert.equals("change", h[1].type)
    assert.same({ "b" }, h[1].old)
    assert.same({ "X" }, h[1].new)
  end)

  it("sits a deletion on the surviving line above the cut", function()
    local h = hunks("a\nb\nc\n", "a\nc\n")
    assert.equals("delete", h[1].type)
    assert.equals(1, h[1].start)
    assert.equals(0, h[1].count)
    assert.same({ "b" }, h[1].old)
  end)

  -- A cut at the top has no line above it to hang the sign on.
  it("marks a deletion at the top of the file as topdelete", function()
    local h = hunks("a\nb\nc\n", "b\nc\n")
    assert.equals("topdelete", h[1].type)
    assert.equals(1, h[1].start)
  end)

  it("reads several hunks in one file", function()
    local h = hunks("a\nb\nc\nd\n", "X\nb\nc\nd\ne\n")
    assert.equals(2, #h)
    assert.equals("change", h[1].type)
    assert.equals("add", h[2].type)
  end)

  it("has nothing to say when the texts match", function()
    assert.same({}, hunks("a\nb\n", "a\nb\n"))
  end)
end)

describe("diff.at / diff.next", function()
  local hunks = {
    { type = "change", start = 2, count = 2 },
    { type = "add", start = 30, count = 1 },
  }

  it("finds the hunk a line sits inside", function()
    assert.equals(hunks[1], diff.at(hunks, 3))
    assert.is_nil(diff.at(hunks, 10))
  end)

  it("walks forwards and backwards, wrapping at the ends", function()
    assert.equals(hunks[2], diff.next(hunks, 5))
    assert.equals(hunks[1], diff.next(hunks, 999)) -- wraps
    assert.equals(hunks[1], diff.next(hunks, 30, true))
    assert.equals(hunks[2], diff.next(hunks, 1, true)) -- wraps
  end)

  it("has nothing to walk to with no hunks", function()
    assert.is_nil(diff.next({}, 1))
  end)
end)

describe("jjsigns.attach", function()
  local jjsigns = require("jjsigns")

  -- gitsigns owns the gutter wherever a git repo exists (a colocated main
  -- workspace included, where @- IS git's HEAD); jjsigns fills the gap in a
  -- secondary workspace, which has no git repo at all.
  it("stays out of a buffer that git can already see", function()
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/lua/jjsigns/init.lua")
    jjsigns.attach(buf)
    assert.equals(
      0,
      #vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("jjsigns"), 0, -1, {})
    )
  end)

  it("has no root for an unnamed buffer", function()
    assert.is_nil(jjsigns.buf_root(vim.api.nvim_create_buf(false, true)))
  end)

  -- A terminal is named term://<cwd>//<pid>:<cmd> before its buftype is set;
  -- vim.fs.root would resolve that relative to the cwd and land on a real
  -- workspace, and the inline view would then paint the whole terminal.
  it("has no root for a URI-named buffer such as a terminal", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "term://" .. vim.fn.getcwd() .. "//123:fish")
    assert.is_nil(jjsigns.buf_root(buf))
  end)
end)

describe("diff.word_ranges", function()
  it("finds the one word that changed on either side", function()
    local o, n = diff.word_ranges("local x = 1", "local y = 1")
    assert.same({ { 6, 7 } }, o)
    assert.same({ { 6, 7 } }, n)
  end)

  it("returns nothing for identical lines", function()
    local o, n = diff.word_ranges("same", "same")
    assert.same({}, o)
    assert.same({}, n)
  end)

  it("marks an appended word on the new side only", function()
    local o, n = diff.word_ranges("foo(x)", "foo(x, y)")
    assert.same({}, o)
    assert.same({ { 5, 8 } }, n)
  end)
end)

describe("diff.inline_marks", function()
  local function hunks(a, b)
    local al, bl = vim.split(a, "\n"), vim.split(b, "\n")
    return diff.from_indices(vim.diff(a, b, { result_type = "indices" }), al, bl), #bl
  end

  local function of_kind(marks, key)
    return vim.tbl_filter(function(m)
      return m.opts[key] ~= nil
    end, marks)
  end

  it("tints added lines and draws nothing virtual", function()
    local h, n = hunks("a\n", "a\nb\nc\n")
    local marks = diff.inline_marks(h, n)
    local ln = of_kind(marks, "line_hl_group")
    assert.equals(2, #ln)
    assert.equals(1, ln[1].row)
    assert.equals("GitSignsAddLn", ln[1].opts.line_hl_group)
    assert.equals(0, #of_kind(marks, "virt_lines"))
  end)

  it("puts a deleted line below the line above the cut", function()
    local h, n = hunks("a\nb\nc\n", "a\nc\n")
    local v = of_kind(diff.inline_marks(h, n), "virt_lines")
    assert.equals(1, #v)
    assert.equals(0, v[1].row)
    assert.is_false(v[1].opts.virt_lines_above)
    assert.equals("b", v[1].opts.virt_lines[1][1][1])
  end)

  it("puts a top-of-file deletion above line 1", function()
    local h, n = hunks("a\nb\n", "b\n")
    local v = of_kind(diff.inline_marks(h, n), "virt_lines")
    assert.equals(0, v[1].row)
    assert.is_true(v[1].opts.virt_lines_above)
  end)

  it("shows a change as old text above, tinted line, and word ranges", function()
    local h, n = hunks("x = 1\n", "x = 2\n")
    local marks = diff.inline_marks(h, n)
    local v = of_kind(marks, "virt_lines")
    assert.equals(1, #v)
    assert.is_true(v[1].opts.virt_lines_above)
    -- The old line is split so the differing word carries the inline colour.
    local chunks = v[1].opts.virt_lines[1]
    assert.same({ "x = ", "GitSignsDeleteVirtLn" }, chunks[1])
    assert.same({ "1", "GitSignsDeleteInline" }, chunks[2])
    local ln = of_kind(marks, "line_hl_group")
    assert.equals("GitSignsChangeLn", ln[1].opts.line_hl_group)
    local w = of_kind(marks, "hl_group")
    assert.equals(1, #w)
    assert.equals(4, w[1].col)
    assert.equals(5, w[1].opts.end_col)
  end)
end)

describe("diff.inline_marks and the sign column", function()
  -- A line_hl_group extmark is a sign as far as the sign column is concerned:
  -- if it outranks the real sign it takes the slot and shows nothing there.
  it("keeps every slot-taking mark below the sign priority", function()
    local a, b = "a\nb\nc\n", "a\nB\n"
    local al, bl = vim.split(a, "\n"), vim.split(b, "\n")
    local h = diff.from_indices(vim.diff(a, b, { result_type = "indices" }), al, bl)
    for _, m in ipairs(diff.inline_marks(h, #bl)) do
      if m.opts.line_hl_group or m.opts.virt_lines then
        assert.is_true(m.opts.priority < 6, "mark would hide the sign")
      end
    end
  end)
end)
