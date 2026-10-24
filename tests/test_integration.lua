-- Simplified integration tests that work reliably
local helpers = require("tests.helpers")

-- Setup and teardown
local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      -- Load plugin with memory backend to avoid file system
      require("code-review").setup({
        comment = {
          storage = { backend = "memory" },
        },
      })
    end,

    pre_case = function()
      -- Reset and reinitialize for clean state
      local state = require("code-review.state")
      local memory = require("code-review.storage.memory")

      -- Use _reset for complete cleanup
      state._reset()
      memory._reset()

      -- Reinitialize
      state.init()

      -- Clear any existing comments
      state.clear()
    end,
  },
})

-- Test basic formatter integration
T["formatter integration"] = function()
  local formatter = require("code-review.formatter")

  -- Test data
  local test_comments = {
    {
      file = "test1.lua",
      line_start = 1,
      line_end = 5,
      comment = "First test comment",
      timestamp = os.time(),
    },
    {
      file = "test1.lua",
      line_start = 10,
      line_end = 10,
      comment = "Second test comment",
      timestamp = os.time(),
    },
    {
      file = "test2.lua",
      line_start = 20,
      line_end = 25,
      comment = "Third test comment",
      timestamp = os.time(),
    },
  }

  -- Format and parse
  local formatted = formatter.format(test_comments)
  local parsed = formatter.parse(formatted)

  -- Verify round-trip
  MiniTest.expect.equality(#parsed, 3)
  MiniTest.expect.equality(parsed[1].file, "test1.lua")
  MiniTest.expect.equality(parsed[1].comment, "First test comment")
  MiniTest.expect.equality(parsed[2].file, "test1.lua")
  MiniTest.expect.equality(parsed[2].comment, "Second test comment")
  MiniTest.expect.equality(parsed[3].file, "test2.lua")
  MiniTest.expect.equality(parsed[3].comment, "Third test comment")
end

-- Test comment formatting
T["comment formatting"] = function()
  local formatter = require("code-review.formatter")

  local test_data = {
    file = "test.lua",
    line_start = 10,
    line_end = 15,
    comment = "This is a test comment\nWith multiple lines",
    context_lines = { "function test()", "  return true", "end" },
  }

  -- Format as markdown
  local lines = formatter.format_single(test_data)

  -- Verify format
  MiniTest.expect.equality(type(lines), "table")
  MiniTest.expect.equality(#lines > 0, true)

  -- Check content
  local content = table.concat(lines, "\n")
  helpers.expect.match(content, "test.lua:10%-15")
  helpers.expect.match(content, "This is a test comment")
  helpers.expect.match(content, "With multiple lines")
  helpers.expect.match(content, "function test")
end

-- Test utils functions
T["utils integration"] = function()
  local utils = require("code-review.utils")

  -- Test path normalization
  local paths = {
    "/absolute/path/file.lua",
    "relative/path/file.lua",
    "~/home/file.lua",
  }

  for _, path in ipairs(paths) do
    local normalized = utils.normalize_path(path)
    MiniTest.expect.equality(type(normalized), "string")
    MiniTest.expect.equality(#normalized > 0, true)
  end

  -- Test filename generation
  local filename = utils.generate_filename("markdown")
  helpers.expect.match(filename, "code%-review%-.*%.md")
end

T["characterwise comment keeps selected text through preview and replies"] = function()
  local ui = require("code-review.ui")
  local state = require("code-review.state")
  local formatter = require("code-review.formatter")

  -- Add a comment from the selected text
  local lines = { "xxéfirst", "middle", "終わりsuffix" }
  local original_input = ui.show_comment_input
  ui.show_comment_input = function(callback)
    callback("Selected text")
  end
  local ok, err = pcall(helpers.with_selection, lines, { 1, 2 }, "v2j0l", function()
    require("code-review.comment").add()
  end)
  ui.show_comment_input = original_input
  if not ok then
    error(err)
  end

  local comment = state.get_comments()[1]
  -- Round-trip through preview formatting
  local formatted = formatter.format({ comment })
  local parsed = formatter.parse(formatted)

  -- Add a reply to the parsed comment
  state.replace_comments(parsed)
  local reply_id = state.add_reply(parsed[1].id, "Reply")
  local reply_comment = state.get_comment(reply_id)
  MiniTest.expect.equality(reply_comment.context_lines, { "éfirst", "middle", "終わ" })
  MiniTest.expect.equality(reply_comment.col_start, 3)
  MiniTest.expect.equality(reply_comment.col_end, 4)
end

-- Test editable preview saves
T["preview editing saves edits through state"] = function()
  local cr = require("code-review")
  local state = require("code-review.state")

  -- Add a comment
  local comment_id = state.add_comment({
    file = "fixture.lua",
    line_start = 10,
    line_end = 10,
    comment = "Original text",
  })

  -- Edit and save preview
  cr.preview()
  local preview_buf = vim.api.nvim_get_current_buf()
  local content = table.concat(vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n")
  local edited = content:gsub("Original text", "Edited text")
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, vim.split(edited, "\n"))
  vim.cmd("write")
  MiniTest.expect.equality(state.get_comment(comment_id).comment, "Edited text")

  -- Verify reopened preview
  vim.cmd("close")
  cr.preview()
  preview_buf = vim.api.nvim_get_current_buf()
  local reopened = table.concat(vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n")
  MiniTest.expect.match(reopened, "Edited text")
  vim.cmd("close")
end

return T
