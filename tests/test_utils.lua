local helpers = require("tests.helpers")
local utils = require("code-review.utils")
local T = MiniTest.new_set()

T["blockwise selection context"] = function()
  local context = helpers.with_selection({
    "outside before",
    "  selected_first()",
    "",
    "  selected_last()",
    "outside after",
  }, { 2, 3 }, "<C-v>jj3l")

  MiniTest.expect.equality(context.line_start, 2)
  MiniTest.expect.equality(context.line_end, 4)
  MiniTest.expect.equality(context.lines, { "elec", "    ", "elec" })
end

T["selection follows exclusive characters and block display columns"] = function()
  local exclusive = helpers.with_selection({ "xxéfirst", "middle", "終わりsuffix" }, { 3, 3 }, "v2k0ll", function()
    vim.o.selection = "exclusive"
    return utils.get_selection_context()
  end)
  MiniTest.expect.equality(exclusive.lines, { "éfirst", "middle", "終" })

  local block = helpers.with_selection({ "0123456789", "\tXYZ", "a界defghi" }, { 1, 2 }, "<C-v>2j2l")
  MiniTest.expect.equality(block.lines, { "234", "   ", " de" })
end

T["blockwise selection reaches each line end after dollar"] = function()
  local context = helpers.with_selection({ "abc", "abcdefghi", "abcde" }, { 1, 1 }, "<C-v>2j$")
  MiniTest.expect.equality(context.lines, { "bc", "bcdefghi", "bcde" })
end

T["blockwise columns include the first cell of tabs and wide characters"] = function()
  local tab = helpers.with_selection({ "\tXYZ", "01234567890" }, { 1, 0 }, "<C-v>j8l")
  MiniTest.expect.equality(tab.lines, { "\tXYZ", "01234567890" })
  MiniTest.expect.equality(tab.col_start, 1)

  local wide = helpers.with_selection({ "a界def", "abcdef" }, { 1, 1 }, "<C-v>j2l")
  MiniTest.expect.equality(wide.lines, { "界d", "bcd" })
  MiniTest.expect.equality(wide.col_start, 2)
  MiniTest.expect.equality(wide.col_end, 4)
end

T["linewise and normal contexts keep whole lines"] = function()
  local lines = { "first line", "middle line", "last line" }
  local linewise = helpers.with_selection(lines, { 1, 2 }, "V2j")
  MiniTest.expect.equality(linewise.lines, lines)
  MiniTest.expect.equality(linewise.col_start, nil)

  local normal = helpers.with_selection(lines, { 2, 2 }, "<Esc>", function()
    return utils.get_selection_context(1)
  end)
  MiniTest.expect.equality(normal.lines, lines)
  MiniTest.expect.equality(normal.col_start, nil)
end

return T
