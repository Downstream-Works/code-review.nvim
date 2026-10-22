-- Helpers for testing

local helpers = {}

-- Add extra expectations
helpers.expect = vim.deepcopy(MiniTest.expect)

-- Add match expectation
helpers.expect.match = MiniTest.new_expectation("string matching", function(str, pattern)
  return str:find(pattern) ~= nil
end, function(str, pattern)
  return string.format("Pattern: %s\nObserved string: %s", vim.inspect(pattern), str)
end)

-- Make helpers
helpers.new_child_neovim = function()
  local args_init = { "-u", "tests/minimal_init.lua" }
  return MiniTest.new_child_neovim({ args = args_init })
end

helpers.with_selection = function(lines, cursor, keys, capture)
  local original_buf = vim.api.nvim_get_current_buf()
  local original_selection = vim.o.selection
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
  vim.bo[buf].tabstop = 8
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, cursor)
  vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(keys, true, false, true))

  local ok, result = pcall(capture or require("code-review.utils").get_selection_context)

  vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
  vim.o.selection = original_selection
  vim.api.nvim_set_current_buf(original_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then
    error(result)
  end
  return result
end

-- Test directory utilities
helpers.test_dir = vim.fn.getcwd() .. "/tests/test_dir"
helpers.test_dir_absolute = vim.fn.fnamemodify(helpers.test_dir, ":p"):gsub("/$", "")

helpers.setup_test_dir = function()
  -- Ensure test directory exists
  vim.fn.mkdir(helpers.test_dir, "p")
end

helpers.cleanup_test_dir = function()
  -- Remove test directory and its contents
  vim.fn.delete(helpers.test_dir, "rf")
end

-- Create a test file
helpers.create_test_file = function(path, content)
  local full_path = helpers.test_dir .. "/" .. path
  local dir = vim.fn.fnamemodify(full_path, ":h")
  vim.fn.mkdir(dir, "p")

  local file = io.open(full_path, "w")
  if file then
    file:write(content)
    file:close()
  end

  return full_path
end

-- Read a test file
helpers.read_test_file = function(path)
  local full_path = helpers.test_dir .. "/" .. path
  local lines = vim.fn.readfile(full_path)
  return table.concat(lines, "\n")
end

-- Check if file exists
helpers.file_exists = function(path)
  local full_path = helpers.test_dir .. "/" .. path
  return vim.fn.filereadable(full_path) == 1
end

return helpers
