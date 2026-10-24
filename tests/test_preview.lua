-- Editable preview tests
local T = MiniTest.new_set()
local config = require("code-review.config")
local original_config

-- Setup and teardown
T.hooks = {
  pre_case = function()
    original_config = vim.deepcopy(config.get_all())
    config.setup({})
  end,

  post_case = function()
    config.setup(original_config)
  end,
}

local function preview_comments()
  return {
    {
      id = "preview-1",
      file = "first.lua",
      line_start = 10,
      line_end = 10,
      context_lines = { "local value = 1" },
      comment = "First text",
      timestamp = 1234567890,
    },
    {
      id = "preview-2",
      file = "second.lua",
      line_start = 20,
      line_end = 20,
      comment = "Second text",
      timestamp = 1234567891,
    },
  }
end

local function replace_text(content, old, new)
  local first, last = content:find(old, 1, true)
  assert(first, "Preview text missing")
  return content:sub(1, first - 1) .. new .. content:sub(last + 1)
end

local function expect_invalid_preview(old, new, pattern)
  local preview = require("code-review.preview")
  local comments = preview_comments()
  local content, snapshot = preview.format(comments)
  local success, err = pcall(preview.parse, replace_text(content, old, new), snapshot)

  MiniTest.expect.equality(success, false)
  MiniTest.expect.match(err, pattern or "Preview .* changed")
  MiniTest.expect.equality(snapshot.comments, comments)
end

T["preview formatting"] = MiniTest.new_set()

T["preview formatting"]["uses detailed output"] = function()
  -- Create comments and capture one date for both renderings
  local formatter = require("code-review.formatter")
  local preview = require("code-review.preview")
  local comments = preview_comments()
  config.setup({ output = { date_format = "2026-10-23 10:00:00" } })

  -- Format the export and editable preview
  local exported = formatter.format(comments)
  local content = preview.format(comments)

  -- Verify identical detailed output
  MiniTest.expect.equality(content, exported)
  MiniTest.expect.match(content, "# Code Review")
  MiniTest.expect.match(content, "%*%*Total Comments%*%*: 2")
  MiniTest.expect.match(content, "## first.lua")
  MiniTest.expect.match(content, "### Line 10")
  MiniTest.expect.match(content, "10: local value = 1")
  MiniTest.expect.match(content, "First text")
end

T["preview formatting"]["keeps detailed previews with minimal exports configured"] = function()
  -- Configure minimal exports and create an editable preview
  local formatter = require("code-review.formatter")
  local preview = require("code-review.preview")
  config.setup({ output = { format = "minimal" } })
  local comments = preview_comments()
  local content, snapshot = preview.format(comments)
  local exported = formatter.format(comments)
  local parsed = preview.parse(replace_text(content, "First text", "Edited text\nAnother line"), snapshot)

  -- Verify exports stay minimal and detailed bodies remain editable
  MiniTest.expect.equality(exported, "first.lua:L10: First text\nsecond.lua:L20: Second text")
  MiniTest.expect.match(content, "# Code Review")
  MiniTest.expect.match(content, "10: local value = 1")
  comments[1].comment = "Edited text\nAnother line"
  MiniTest.expect.equality(parsed, comments)
end

T["preview formatting"]["captures independent comment metadata"] = function()
  local preview = require("code-review.preview")
  local comments = preview_comments()
  local original = vim.deepcopy(comments)
  local content, snapshot = preview.format(comments)
  comments[1].comment = "Changed input"
  comments[1].context_lines[1] = "Changed context"

  local parsed = preview.parse(content, snapshot)
  MiniTest.expect.equality(parsed, original)
  parsed[1].context_lines[1] = "Changed result"
  MiniTest.expect.equality(preview.parse(content, snapshot), original)
end

T["preview parsing"] = MiniTest.new_set()

T["preview parsing"]["preserves arbitrary Markdown and blank lines in edited bodies"] = function()
  -- Create a preview and Markdown containing an existing location heading
  local preview = require("code-review.preview")
  local comments = preview_comments()
  local content, snapshot = preview.format(comments)
  local edited = table.concat({
    "",
    "First paragraph",
    "",
    "## Findings",
    "",
    "### Details",
    "### Line 10",
    "**Time**: Body metadata example",
    "---",
    "```lua",
    'print("important")',
    "```",
    "After code",
    "",
    "```",
    "plain fenced example",
    "```",
    "Final paragraph",
    "<!-- Review note -->",
    "",
    "",
  }, "\n")

  -- Replace the first body with the Markdown
  local parsed = preview.parse(replace_text(content, "First text", edited), snapshot)

  -- Verify the body preserves its Markdown and location heading
  comments[1].comment = edited
  MiniTest.expect.equality(parsed, comments)
end

T["preview parsing"]["preserves identity and selection metadata when editing replies"] = function()
  local preview = require("code-review.preview")
  local reply = {
    id = "reply-id",
    parent_id = "root-id",
    thread_id = "root-id_thread",
    author = "Original Author",
    file = "fixture.lua",
    line_start = 10,
    line_end = 12,
    col_start = 2,
    col_end = 6,
    context_lines = { "éfirst", "middle", "終わ" },
    timestamp = 1234567890,
    comment = "Reply text",
  }
  local content, snapshot = preview.format({ reply })

  local parsed = preview.parse(replace_text(content, "Reply text", "Edited reply"), snapshot)
  local expected = vim.deepcopy(reply)
  expected.comment = "Edited reply"
  MiniTest.expect.equality(parsed, { expected })
  MiniTest.expect.equality(snapshot.comments, { reply })
end

T["preview parsing"]["allows an original timestamp line inside a comment body"] = function()
  -- Create a body containing its own original timestamp line
  local preview = require("code-review.preview")
  local comments = preview_comments()
  local timestamp = os.date(config.get("output.date_format"), comments[1].timestamp)
  comments[1].comment = "Discussion\n**Time**: " .. timestamp .. "\nAfter"
  local content, snapshot = preview.format(comments)

  -- Save the unchanged body
  local parsed = preview.parse(content, snapshot)

  MiniTest.expect.equality(parsed, comments)
end

T["preview parsing"]["allows adding an original timestamp line to a comment body"] = function()
  -- Create a preview and a body containing its timestamp
  local preview = require("code-review.preview")
  local comments = preview_comments()
  local content, snapshot = preview.format(comments)
  local timestamp = os.date(config.get("output.date_format"), comments[1].timestamp)
  local body = "Discussion\n**Time**: " .. timestamp .. "\nAfter"

  -- Edit the body with the isolated timestamp line
  local parsed = preview.parse(replace_text(content, "First text", body), snapshot)

  comments[1].comment = body
  MiniTest.expect.equality(parsed, comments)
end

T["preview parsing"]["keeps following sections after an unclosed body fence"] = function()
  -- Create a preview and an incomplete fenced example
  local preview = require("code-review.preview")
  local comments = preview_comments()
  local content, snapshot = preview.format(comments)
  local body = "```lua\nlocal value = 2"

  -- Edit the first body before closing its Markdown fence
  local parsed = preview.parse(replace_text(content, "First text", body), snapshot)

  -- Verify both comments remain and the body is preserved
  comments[1].comment = body
  MiniTest.expect.equality(parsed, comments)
end

T["preview parsing"]["allows empty comment bodies"] = function()
  local preview = require("code-review.preview")
  local comments = preview_comments()
  local content, snapshot = preview.format(comments)

  local parsed = preview.parse(replace_text(content, "First text", ""), snapshot)
  comments[1].comment = ""
  MiniTest.expect.equality(parsed, comments)
end

T["preview parsing"]["allows removing the final blank line"] = function()
  -- Create a preview with two comments
  local preview = require("code-review.preview")
  local comments = preview_comments()
  local content, snapshot = preview.format(comments)

  -- Remove the final blank line
  local parsed = preview.parse(content:sub(1, -2), snapshot)

  -- Verify both comments retain their bodies
  MiniTest.expect.equality(parsed, comments)
end

T["preview parsing"]["supports repeated edits against the original snapshot"] = function()
  local preview = require("code-review.preview")
  local comments = preview_comments()
  local content, snapshot = preview.format(comments)
  local first_edit = replace_text(content, "First text", "First edit")
  local first_parsed = preview.parse(first_edit, snapshot)
  local second_edit = replace_text(first_edit, "First edit", "Second edit\n\n")
  local second_parsed = preview.parse(second_edit, snapshot)

  local expected = vim.deepcopy(comments)
  expected[1].comment = "First edit"
  MiniTest.expect.equality(first_parsed, expected)
  expected[1].comment = "Second edit\n\n"
  MiniTest.expect.equality(second_parsed, expected)
  MiniTest.expect.equality(preview.parse(content, snapshot), comments)
end

T["preview parsing"]["allows deletion of a complete comment section"] = function()
  local preview = require("code-review.preview")
  local comments = preview_comments()
  comments[2].file = comments[1].file
  local content, snapshot = preview.format(comments)
  local first = assert(content:find("### Line 10", 1, true))
  local second = assert(content:find("### Line 20", 1, true))
  local edited = content:sub(1, first - 1) .. content:sub(second)

  MiniTest.expect.equality(preview.parse(edited, snapshot), { comments[2] })
end

T["preview parsing"]["allows section deletion while editing both neighbors"] = function()
  -- Create three comments in one file
  local preview = require("code-review.preview")
  local comments = preview_comments()
  comments[2].file = comments[1].file
  comments[3] = vim.deepcopy(comments[2])
  comments[3].id = "preview-3"
  comments[3].line_start = 30
  comments[3].line_end = 30
  comments[3].comment = "Third text"
  local content, snapshot = preview.format(comments)
  local second = assert(content:find("### Line 20", 1, true))
  local third = assert(content:find("### Line 30", 1, true))

  -- Delete the middle section and edit the remaining bodies
  local edited = content:sub(1, second - 1) .. content:sub(third)
  edited = replace_text(edited, "First text", "First edit\n\nWith another paragraph.")
  edited = replace_text(edited, "Third text", "Third edit")
  local parsed = preview.parse(edited, snapshot)

  -- Verify the retained comments keep their identities and edited bodies
  local expected = { vim.deepcopy(comments[1]), vim.deepcopy(comments[3]) }
  expected[1].comment = "First edit\n\nWith another paragraph."
  expected[2].comment = "Third edit"
  MiniTest.expect.equality(parsed, expected)
end

T["preview parsing"]["allows deletion of all comment sections"] = function()
  local preview = require("code-review.preview")
  local content, snapshot = preview.format(preview_comments())
  local header = table.concat(vim.list_slice(vim.split(content, "\n"), 1, 5), "\n")

  MiniTest.expect.equality(preview.parse(header, snapshot), {})
end

T["preview parsing"]["allows deletion of a complete file section"] = function()
  local preview = require("code-review.preview")
  local comments = preview_comments()
  local content, snapshot = preview.format(comments)
  local first = assert(content:find("## first.lua", 1, true))
  local second = assert(content:find("## second.lua", 1, true))
  local edited = content:sub(1, first - 1) .. content:sub(second)

  MiniTest.expect.equality(preview.parse(edited, snapshot), { comments[2] })
end

T["preview parsing"]["preserves identities when file sections are reordered"] = function()
  local preview = require("code-review.preview")
  local comments = preview_comments()
  local content, snapshot = preview.format(comments)
  local first = assert(content:find("## first.lua", 1, true))
  local second = assert(content:find("## second.lua", 1, true))
  local header = content:sub(1, first - 1)
  local first_section = content:sub(first, second - 1)
  local second_section = content:sub(second)
  local edited = header .. second_section .. "\n" .. first_section:sub(1, -2)

  MiniTest.expect.equality(preview.parse(edited, snapshot), { comments[2], comments[1] })
end

T["preview parsing"]["allows reordering sections while editing their bodies"] = function()
  -- Create two sections in one file
  local preview = require("code-review.preview")
  local comments = preview_comments()
  comments[2].file = comments[1].file
  local content, snapshot = preview.format(comments)
  local first = assert(content:find("### Line 10", 1, true))
  local second = assert(content:find("### Line 20", 1, true))

  -- Move the second section first and edit both bodies
  local edited = content:sub(1, first - 1) .. content:sub(second) .. "\n" .. content:sub(first, second - 2)
  edited = replace_text(edited, "First text", "First edit")
  edited = replace_text(edited, "Second text", "Second edit")
  local parsed = preview.parse(edited, snapshot)

  -- Verify the new order and original identities
  local expected = { vim.deepcopy(comments[2]), vim.deepcopy(comments[1]) }
  expected[1].comment = "Second edit"
  expected[2].comment = "First edit"
  MiniTest.expect.equality(parsed, expected)
end

T["preview parsing"]["preserves reply identities when comment sections are reordered"] = function()
  local preview = require("code-review.preview")
  local comments = preview_comments()
  comments[1].context_lines = nil
  comments[1].thread_id = "preview-1_thread"
  comments[2].file = comments[1].file
  comments[2].line_start = 10
  comments[2].line_end = 10
  comments[2].thread_id = comments[1].thread_id
  comments[2].parent_id = comments[1].id
  local content, snapshot = preview.format(comments)
  local first = assert(content:find("### Line 10", 1, true))
  local second = assert(content:find("### Line 10", first + 1, true))
  local edited = content:sub(1, first - 1) .. content:sub(second) .. "\n" .. content:sub(first, second - 2)
  MiniTest.expect.equality(preview.parse(edited, snapshot), { comments[2], comments[1] })
end

T["preview parsing"]["uses unchanged bodies to identify edits with identical structures"] = function()
  local preview = require("code-review.preview")
  local comments = preview_comments()
  comments[2] = vim.deepcopy(comments[1])
  comments[2].id = "preview-2"
  comments[2].comment = "Second text"
  local content, snapshot = preview.format(comments)

  local parsed = preview.parse(replace_text(content, "First text", "Edited text"), snapshot)
  local expected = vim.deepcopy(comments)
  expected[1].comment = "Edited text"
  table.sort(parsed, function(a, b)
    return a.id < b.id
  end)
  MiniTest.expect.equality(parsed, expected)
end

T["preview parsing"]["allows editing both bodies with identical structures"] = function()
  local preview = require("code-review.preview")
  local comments = preview_comments()
  comments[2] = vim.deepcopy(comments[1])
  comments[2].id = "preview-2"
  comments[2].comment = "Second text"
  local content, snapshot = preview.format(comments)
  local edited = replace_text(content, "First text", "First edit")
  edited = replace_text(edited, "Second text", "Second edit")

  local parsed = preview.parse(edited, snapshot)
  comments[1].comment = "First edit"
  comments[2].comment = "Second edit"
  MiniTest.expect.equality(parsed, comments)
end

T["preview parsing"]["rejects a changed review title"] = function()
  expect_invalid_preview("# Code Review", "# Changed Review")
end

T["preview parsing"]["rejects changed date metadata"] = function()
  expect_invalid_preview("**Date**:", "**Edited Date**:")
end

T["preview parsing"]["rejects a changed comment count"] = function()
  expect_invalid_preview("**Total Comments**: 2", "**Total Comments**: 1")
end

T["preview parsing"]["rejects a changed first file heading"] = function()
  expect_invalid_preview("## first.lua", "## renamed.lua")
end

T["preview parsing"]["rejects a changed later file heading"] = function()
  expect_invalid_preview("## second.lua", "## renamed-second.lua")
end

T["preview parsing"]["rejects a changed location heading"] = function()
  expect_invalid_preview("### Line 20", "### Line 21")
end

T["preview parsing"]["rejects changed timestamp metadata"] = function()
  expect_invalid_preview("**Time**:", "**Changed Time**:")
end

T["preview parsing"]["rejects removed timestamp metadata"] = function()
  -- Create a preview with two original timestamp lines
  local preview = require("code-review.preview")
  local content, snapshot = preview.format(preview_comments())
  local second = assert(content:find("### Line 20\n", 1, true))
  local timestamp = content:match("(%*%*Time%*%*: [^\n]+\n)", second)

  -- Remove the later timestamp while keeping its section
  local edited = content:sub(1, second - 1) .. replace_text(content:sub(second), timestamp, "")
  local success, err = pcall(preview.parse, edited, snapshot)

  -- Verify the retained structure must still match
  MiniTest.expect.equality(success, false)
  MiniTest.expect.match(err, "Preview comment structure was changed")
end

T["preview parsing"]["rejects changed context code"] = function()
  expect_invalid_preview("10: local value = 1", "10: local value = 2")
end

T["preview parsing"]["rejects changed context fences"] = function()
  expect_invalid_preview("```\n10:", "```lua\n10:")
end

T["preview parsing"]["rejects a removed section separator"] = function()
  expect_invalid_preview("First text\n\n", "First text\n")
end

T["preview parsing"]["rejects partial section deletion"] = function()
  expect_invalid_preview("### Line 20\n", "")
end

T["preview parsing"]["rejects duplicated sections"] = function()
  local preview = require("code-review.preview")
  local content, snapshot = preview.format(preview_comments())
  local second = assert(content:find("## second.lua", 1, true))

  local success, err = pcall(preview.parse, content .. "\n" .. content:sub(second), snapshot)
  MiniTest.expect.equality(success, false)
  MiniTest.expect.match(err, "Duplicate preview comment section")
end

T["preview parsing"]["rejects minimal content replacing the preview"] = function()
  local preview = require("code-review.preview")
  local _, snapshot = preview.format(preview_comments())

  local success, err = pcall(preview.parse, "first.lua:L10: unparseable preview", snapshot)
  MiniTest.expect.equality(success, false)
  MiniTest.expect.match(err, "Preview review header was changed")
end

return T
