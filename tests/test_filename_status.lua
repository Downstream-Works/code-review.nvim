local state = require("code-review.state")
local file_storage = require("code-review.storage.file")
local config = require("code-review.config")

local test_dir = vim.fn.tempname()
local original_config

local T = MiniTest.new_set()

-- Setup and teardown hooks
T["filename status management"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      original_config = vim.deepcopy(config.get_all())

      -- Reset state
      state._reset()

      -- Initialize plugin with file storage and status management enabled for testing
      require("code-review").setup({
        comment = {
          storage = { backend = "file", file = { dir = test_dir } },
          claude_code_author = "Claude Code",
          status_management = true, -- Enable for testing
        },
      })
      state.clear()
    end,
    post_case = function()
      -- Clean up test files
      vim.fn.delete(test_dir, "rf")
      config.setup(original_config)
      state._reset()
      state.init()
    end,
  },
})

T["filename status management"]["parse_filename extracts status and id"] = function()
  -- Save original status_management setting
  local original_status_management = config.get("comment.status_management")

  -- Test with status_management enabled
  config.get_all().comment.status_management = true

  local test_cases_enabled = {
    {
      filename = "action-required_1234567890.md",
      expected_status = "action-required",
      expected_id = "1234567890",
    },
    {
      filename = "waiting-review_9876543210.md",
      expected_status = "waiting-review",
      expected_id = "9876543210",
    },
    {
      filename = "resolved_1111111111.md",
      expected_status = "resolved",
      expected_id = "1111111111",
    },
    {
      filename = "action-required_1234567890_thread.md",
      expected_status = "action-required",
      expected_id = "1234567890_thread",
    },
    -- Test legacy format (backward compatibility)
    {
      filename = "1234567890.md",
      expected_status = "action-required",
      expected_id = "1234567890",
    },
    -- Test invalid formats
    {
      filename = "invalid.txt",
      expected_status = nil,
      expected_id = nil,
    },
  }

  for _, test in ipairs(test_cases_enabled) do
    local status, id = file_storage.parse_filename(test.filename)
    MiniTest.expect.equality(status, test.expected_status)
    MiniTest.expect.equality(id, test.expected_id)
  end

  -- Test with status_management disabled
  config.get_all().comment.status_management = false

  local test_cases_disabled = {
    {
      filename = "action-required_1234567890.md",
      expected_status = nil,
      expected_id = "action-required_1234567890", -- Entire string is treated as ID
    },
    {
      filename = "1234567890.md",
      expected_status = nil,
      expected_id = "1234567890",
    },
    {
      filename = "invalid.txt",
      expected_status = nil,
      expected_id = nil,
    },
  }

  for _, test in ipairs(test_cases_disabled) do
    local status, id = file_storage.parse_filename(test.filename)
    MiniTest.expect.equality(status, test.expected_status)
    MiniTest.expect.equality(id, test.expected_id)
  end

  -- Restore original setting
  config.get_all().comment.status_management = original_status_management
end

T["filename status management"]["make_filename creates correct filename"] = function()
  -- Save original status_management setting
  local original_status_management = config.get("comment.status_management")

  -- Test with status_management enabled
  config.get_all().comment.status_management = true

  local test_cases_enabled = {
    {
      id = "1234567890",
      status = "action-required",
      expected = "action-required_1234567890.md",
    },
    {
      id = "9876543210",
      status = "waiting-review",
      expected = "waiting-review_9876543210.md",
    },
    {
      id = "1111111111",
      status = "resolved",
      expected = "resolved_1111111111.md",
    },
    {
      id = "1234567890_thread",
      status = "action-required",
      expected = "action-required_1234567890_thread.md",
    },
  }

  for _, test in ipairs(test_cases_enabled) do
    local filename = file_storage.make_filename(test.id, test.status)
    MiniTest.expect.equality(filename, test.expected)
  end

  -- Test with status_management disabled
  config.get_all().comment.status_management = false

  local test_cases_disabled = {
    {
      id = "1234567890",
      status = "action-required", -- Status should be ignored
      expected = "1234567890.md",
    },
    {
      id = "9876543210",
      status = "waiting-review", -- Status should be ignored
      expected = "9876543210.md",
    },
    {
      id = "1234567890",
      status = nil,
      expected = "1234567890.md",
    },
  }

  for _, test in ipairs(test_cases_disabled) do
    local filename = file_storage.make_filename(test.id, test.status)
    MiniTest.expect.equality(filename, test.expected)
  end

  -- Restore original setting
  config.get_all().comment.status_management = original_status_management
end

T["filename status management"]["determine_thread_status returns correct status"] = function()
  -- Test status determination based on author
  local test_cases = {
    {
      comments = { { author = "Claude Code", comment = "Test", time = os.time() } },
      expected = "waiting-review",
      description = "Claude Code as latest author should result in waiting-review",
    },
    {
      comments = { { author = "User", comment = "Test", time = os.time() } },
      expected = "action-required",
      description = "Non-Claude Code author should result in action-required",
    },
    {
      comments = {
        { author = "User", comment = "Initial", time = os.time() - 100 },
        { author = "Claude Code", comment = "Reply", time = os.time() },
      },
      expected = "waiting-review",
      description = "Claude Code as latest reply should result in waiting-review",
    },
    {
      comments = {
        { author = "Claude Code", comment = "Initial", time = os.time() - 100 },
        { author = "User", comment = "Reply", time = os.time() },
      },
      expected = "action-required",
      description = "User as latest reply should result in action-required",
    },
    {
      comments = {},
      expected = "action-required",
      description = "Empty comments should result in action-required",
    },
  }

  for _, test in ipairs(test_cases) do
    local status = file_storage.determine_thread_status(test.comments)
    MiniTest.expect.equality(status, test.expected)
  end
end

T["filename status management"]["file rename on reply"] = function()
  -- Create a root comment
  local root_id = state.add_comment({
    file = "test.lua",
    line_start = 1,
    line_end = 1,
    comment = "Initial comment",
    author = "User",
  })

  -- Wait a bit to ensure file is written
  vim.wait(100)

  -- Check initial filename
  local files = vim.fn.glob(test_dir .. "/action-required_" .. root_id .. ".md", false, true)
  MiniTest.expect.equality(#files, 1)

  -- Add a reply from Claude Code
  local original_user = vim.env.USER
  MiniTest.finally(function()
    vim.env.USER = original_user
  end)
  vim.env.USER = "Claude Code"
  state.add_reply(root_id, "I'll fix this")

  -- Wait for file operations
  vim.wait(100)

  -- Check that file was renamed to waiting-review
  local old_files = vim.fn.glob(test_dir .. "/action-required_" .. root_id .. ".md", false, true)
  MiniTest.expect.equality(#old_files, 0)

  local new_files = vim.fn.glob(test_dir .. "/waiting-review_" .. root_id .. ".md", false, true)
  MiniTest.expect.equality(#new_files, 1)
end

T["filename status management"]["thread file operations"] = function()
  -- Create a thread by adding a comment
  local comment_id = state.add_comment({
    file = "test_thread.lua",
    line_start = 10,
    line_end = 10,
    comment = "Thread test comment",
    author = "User",
  })

  -- Wait for file creation
  vim.wait(100)

  -- Check comment file exists with correct status
  local comment_files = vim.fn.glob(test_dir .. "/action-required_" .. comment_id .. ".md", false, true)
  MiniTest.expect.equality(#comment_files, 1)

  -- Add reply from Claude Code to trigger status change
  local original_user = vim.env.USER
  MiniTest.finally(function()
    vim.env.USER = original_user
  end)
  vim.env.USER = "Claude Code"
  state.add_reply(comment_id, "Working on it")

  -- Wait for file operations
  vim.wait(100)

  -- Check that comment file was renamed
  local old_comment_files = vim.fn.glob(test_dir .. "/action-required_" .. comment_id .. ".md", false, true)
  MiniTest.expect.equality(#old_comment_files, 0)

  local new_comment_files = vim.fn.glob(test_dir .. "/waiting-review_" .. comment_id .. ".md", false, true)
  MiniTest.expect.equality(#new_comment_files, 1)
end

T["filename status management"]["wildcard search for file updates"] = function()
  -- Create a comment
  local comment_id = state.add_comment({
    file = "wildcard_test.lua",
    line_start = 5,
    line_end = 5,
    comment = "Test wildcard search",
    author = "User",
  })

  -- Wait for file creation
  vim.wait(100)

  -- Update comment (should find file regardless of status prefix)
  local success = state.update_comment(comment_id, {
    comment = "Updated comment text",
  })
  MiniTest.expect.equality(success, true)

  -- Wait for update
  vim.wait(100)

  -- Read the file to verify update
  local files = vim.fn.glob(test_dir .. "/*_" .. comment_id .. ".md", false, true)
  MiniTest.expect.equality(#files, 1)

  local content = vim.fn.readfile(files[1])
  local found_updated_text = false
  for _, line in ipairs(content) do
    if line:match("Updated comment text") then
      found_updated_text = true
      break
    end
  end
  MiniTest.expect.equality(found_updated_text, true)
end

T["filename status management"]["status preserved in list view"] = function()
  -- Create comments with different statuses
  local comment1_id = state.add_comment({
    id = "list-user",
    file = "list_test.lua",
    line_start = 1,
    line_end = 1,
    comment = "Comment from user",
    author = "User",
  })

  local comment2_id = state.add_comment({
    id = "list-review",
    file = "list_test.lua",
    line_start = 5,
    line_end = 5,
    comment = "Another comment from user",
    author = "User",
  })

  -- Add a reply from Claude Code to set waiting-review status
  local original_user = vim.env.USER
  MiniTest.finally(function()
    vim.env.USER = original_user
  end)
  vim.env.USER = "Claude Code"
  state.add_reply(comment2_id, "Ready for review")

  -- Wait for files to be created
  vim.wait(100)

  -- Get all comments
  local comments = state.get_comments()

  -- Find our test comments
  local comment1, comment2
  for _, c in ipairs(comments) do
    if c.id == comment1_id then
      comment1 = c
    elseif c.id == comment2_id then
      comment2 = c
    end
  end

  -- Check that thread_status is set based on filename (when status_management is enabled)
  MiniTest.expect.equality(comment1.thread_status, "action-required")
  MiniTest.expect.equality(comment2.thread_status, "waiting-review")
end

T["filename status management"]["resolve thread updates filename"] = function()
  -- Create a comment
  local comment_id = state.add_comment({
    file = "resolve_test.lua",
    line_start = 1,
    line_end = 1,
    comment = "To be resolved",
    author = "User",
  })

  local thread_id = comment_id .. "_thread"

  -- Wait for file creation
  vim.wait(100)

  -- Resolve the thread
  state.resolve_thread(thread_id)

  -- Wait for file operations
  vim.wait(100)

  -- Check that comment file was renamed to resolved
  local action_files = vim.fn.glob(test_dir .. "/action-required_" .. comment_id .. ".md", false, true)
  MiniTest.expect.equality(#action_files, 0)

  local resolved_files = vim.fn.glob(test_dir .. "/resolved_" .. comment_id .. ".md", false, true)
  MiniTest.expect.equality(#resolved_files, 1)
end

T["filename status management"]["status_management disabled"] = function()
  -- Save original setting
  local original_status_management = config.get("comment.status_management")

  -- Disable status management
  config.get_all().comment.status_management = false

  -- Clear any existing comments
  state.clear()

  -- Create a comment
  local comment_id = state.add_comment({
    file = "disabled_test.lua",
    line_start = 1,
    line_end = 1,
    comment = "Test without status management",
    author = "User",
  })

  -- Wait for file creation
  vim.wait(100)

  -- Check that file has no status prefix
  local status_files = vim.fn.glob(test_dir .. "/*_" .. comment_id .. ".md", false, true)
  MiniTest.expect.equality(#status_files, 0)

  local plain_files = vim.fn.glob(test_dir .. "/" .. comment_id .. ".md", false, true)
  MiniTest.expect.equality(#plain_files, 1)

  -- Add a reply
  state.add_reply(comment_id, "Reply without status change")

  -- Wait for file operations
  vim.wait(100)

  -- Check that file still has no status prefix
  local status_files_after = vim.fn.glob(test_dir .. "/*_" .. comment_id .. ".md", false, true)
  MiniTest.expect.equality(#status_files_after, 0)

  local plain_files_after = vim.fn.glob(test_dir .. "/" .. comment_id .. ".md", false, true)
  MiniTest.expect.equality(#plain_files_after, 1)

  -- Resolve thread should not rename file and should show warning
  local thread_id = comment_id .. "_thread"

  -- Capture notifications
  local notifications = {}
  local original_notify = vim.notify
  vim.notify = function(msg, level) -- luacheck: ignore 122
    table.insert(notifications, { msg = msg, level = level })
  end

  local success = state.resolve_thread(thread_id)

  -- Restore original notify
  vim.notify = original_notify -- luacheck: ignore 122

  -- Should return false when status management is disabled
  MiniTest.expect.equality(success, false)

  -- Should show warning notification
  MiniTest.expect.equality(#notifications, 1)
  MiniTest.expect.equality(
    notifications[1].msg,
    "Status management is disabled. Enable 'status_management' to resolve threads."
  )
  MiniTest.expect.equality(notifications[1].level, vim.log.levels.WARN)

  -- Wait for operations
  vim.wait(100)

  -- File should still have no status prefix
  local resolved_files = vim.fn.glob(test_dir .. "/resolved_" .. comment_id .. ".md", false, true)
  MiniTest.expect.equality(#resolved_files, 0)

  local plain_files_final = vim.fn.glob(test_dir .. "/" .. comment_id .. ".md", false, true)
  MiniTest.expect.equality(#plain_files_final, 1)

  -- Restore original setting
  config.get_all().comment.status_management = original_status_management
end

return T
