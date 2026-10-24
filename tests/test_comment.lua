local state = require("code-review.state")
local comment = require("code-review.comment")
local buffers = {}

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      require("code-review").setup({
        comment = {
          storage = { backend = "memory" },
        },
      })
    end,

    pre_case = function()
      state._reset()
      require("code-review.storage.memory")._reset()
      state.init()
      state.clear()
    end,

    post_case = function()
      state.clear()
      for _, buf in ipairs(buffers) do
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      buffers = {}
    end,
  },
})

local function create_buffer(name)
  local buf = vim.api.nvim_create_buf(false, true)
  table.insert(buffers, buf)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first", "commented line", "last" })
  return buf
end

local function expect_indicators(buf, text)
  local ns = vim.api.nvim_get_namespaces().CodeReviewVirtualText
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local signs = vim.fn.sign_getplaced(buf, { group = "CodeReviewSigns" })[1].signs
  MiniTest.expect.equality(#marks, text and 1 or 0)
  MiniTest.expect.equality(#signs, text and 1 or 0)
  if text then
    MiniTest.expect.equality(marks[1][2], 1)
    MiniTest.expect.match(marks[1][4].virt_text[1][1], text)
    MiniTest.expect.equality(signs[1].lnum, 2)
  end
end

T["basename comment renders in both Diffview versions and its source buffer"] = function()
  local root = vim.fn.getcwd()
  local base = create_buffer("diffview://" .. root .. "/.git/a1f12595014/tests/fixture.lua")
  local index = create_buffer("diffview://" .. root .. "/.git/:0:/tests/fixture.lua")
  local source = create_buffer(root .. "/tests/fixture.lua")
  local unrelated = create_buffer(root .. "/other/fixture.lua")

  local id = state.add_comment({
    file = "fixture.lua",
    line_start = 2,
    line_end = 2,
    comment = "Saved comment",
  })

  for _, buf in ipairs({ base, index, source }) do
    expect_indicators(buf, "Saved comment")
  end
  expect_indicators(unrelated)

  -- Refresh replaces indicators and deletion clears every version
  comment.update_indicators()
  for _, buf in ipairs({ base, index, source }) do
    expect_indicators(buf, "Saved comment")
  end
  state.delete_comment(id)
  for _, buf in ipairs({ base, index, source }) do
    expect_indicators(buf)
  end
end

T["file paths match Diffview sources without matching other files"] = function()
  local root = vim.fn.getcwd()
  local base = create_buffer("diffview://" .. root .. "/.git/a1f12595014/tests/fixture.lua")
  local index = create_buffer("diffview://" .. root .. "/.git/:0:/tests/fixture.lua")
  local unrelated = create_buffer("diffview://" .. root .. "/.git/:0:/other/fixture.lua")
  local source = create_buffer(root .. "/tests/fixture.lua")

  for _, file in ipairs({ "tests/fixture.lua", root .. "/tests/fixture.lua" }) do
    local id = state.add_comment({
      file = file,
      line_start = 2,
      line_end = 2,
      comment = "Path comment",
    })
    for _, buf in ipairs({ base, index, source }) do
      expect_indicators(buf, "Path comment")
    end
    expect_indicators(unrelated)
    state.delete_comment(id)
  end
end

T["ambiguous basename comments skip unrelated Diffview source files"] = function()
  local root = vim.fn.getcwd()
  local first = create_buffer("diffview://" .. root .. "/.git/:0:/tests/fixture.lua")
  local second = create_buffer("diffview://" .. root .. "/.git/:0:/other/fixture.lua")

  state.add_comment({
    file = "fixture.lua",
    line_start = 2,
    line_end = 2,
    comment = "Ambiguous comment",
  })

  expect_indicators(first)
  expect_indicators(second)
end

T["qualified paths skip Diffview sources from another project"] = function()
  local root = vim.fn.getcwd()
  local source = create_buffer(root .. "/tests/fixture.lua")
  local unrelated = create_buffer("diffview://" .. root .. "-other/.git/:0:/tests/fixture.lua")

  state.add_comment({
    file = "tests/fixture.lua",
    line_start = 2,
    line_end = 2,
    comment = "Project comment",
  })

  expect_indicators(source, "Project comment")
  expect_indicators(unrelated)
end

return T
