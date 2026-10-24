local M = {}

local config = require("code-review.config")

---@param comment table
---@return string
local function format_range(comment)
  if comment.col_start and comment.col_end then
    if comment.line_start == comment.line_end then
      return string.format("%d:%d-%d", comment.line_start, comment.col_start, comment.col_end)
    end
    return string.format("%d:%d-%d:%d", comment.line_start, comment.col_start, comment.line_end, comment.col_end)
  end
  if comment.line_start == comment.line_end then
    return tostring(comment.line_start)
  end
  return string.format("%d-%d", comment.line_start, comment.line_end)
end

--- Render detailed Markdown and observe each header, file, and comment structure
---@private
---@param comments table[]
---@param on_structure? fun(lines: string[], start: integer, file?: string, comment?: table)
---@return string
function M._format_markdown(comments, on_structure)
  local lines = {}
  local date_format = config.get("output.date_format")

  -- Header
  table.insert(lines, "# Code Review")
  table.insert(lines, "")
  table.insert(lines, string.format("**Date**: %s", os.date(date_format)))
  table.insert(lines, string.format("**Total Comments**: %d", #comments))
  table.insert(lines, "")

  if on_structure then
    on_structure(lines, 1)
  end

  -- Group comments by file
  local by_file = {}
  for _, comment in ipairs(comments) do
    by_file[comment.file] = by_file[comment.file] or {}
    table.insert(by_file[comment.file], comment)
  end

  -- Sort files
  local files = vim.tbl_keys(by_file)
  table.sort(files)

  -- Format each file's comments
  for _, file in ipairs(files) do
    table.insert(lines, string.format("## %s", file))
    table.insert(lines, "")
    if on_structure then
      on_structure(lines, #lines - 1, file)
    end

    local file_comments = by_file[file]
    -- Sort by line number
    table.sort(file_comments, function(a, b)
      return a.line_start < b.line_start
    end)

    for _, comment in ipairs(file_comments) do
      local section_start = #lines + 1
      -- Location header
      if comment.line_start == comment.line_end then
        table.insert(lines, "### Line " .. format_range(comment))
      else
        table.insert(lines, "### Lines " .. format_range(comment))
      end

      -- Add timestamp
      table.insert(lines, string.format("**Time**: %s", os.date(date_format, comment.timestamp)))
      table.insert(lines, "")

      -- Context code if available
      if comment.context_lines and #comment.context_lines > 0 then
        table.insert(lines, "```")
        for i, line in ipairs(comment.context_lines) do
          local line_num = comment.line_start + i - 1
          table.insert(lines, string.format("%d: %s", line_num, line))
        end
        table.insert(lines, "```")
        table.insert(lines, "")
      end
      if on_structure then
        on_structure(lines, section_start, file, comment)
      end

      -- Comment text
      table.insert(lines, comment.comment)
      table.insert(lines, "")
    end
  end

  return table.concat(lines, "\n")
end

--- Format comments to minimal format (flat, for AI)
---@param comments table[]
---@return string
local function format_minimal(comments)
  local lines = {}
  for _, comment in ipairs(comments) do
    local location = comment.file .. ":L" .. format_range(comment)
    -- Join multi-line comments into single line
    local text = comment.comment:gsub("\n", " ")
    table.insert(lines, location .. ": " .. text)
  end
  return table.concat(lines, "\n")
end

--- Format comments based on configured format
---@param comments table[]
---@return string
function M.format(comments)
  local format_type = config.get("output.format") or "detailed"
  if format_type == "minimal" then
    return format_minimal(comments)
  else
    return M._format_markdown(comments)
  end
end

--- Format a single comment for preview display (always detailed)
--- This is used for Telescope, fzf-lua, and buffer previews
---@param comment table The comment object
---@param opts? { include_header?: boolean, use_ansi?: boolean }
---@return string[] Lines of formatted markdown
function M.format_single(comment, opts)
  opts = opts or {}
  local include_header = opts.include_header ~= false -- default true
  local use_ansi = opts.use_ansi or false

  local lines = {}

  -- ANSI color codes for fzf
  local colors = {
    header = use_ansi and "\x1b[1;34m" or "", -- Bold blue
    section = use_ansi and "\x1b[1;33m" or "", -- Bold yellow
    code = use_ansi and "\x1b[36m" or "", -- Cyan
    reset = use_ansi and "\x1b[0m" or "", -- Reset
  }

  if include_header then
    -- Header with file and line info
    local range = comment.col_start and comment.col_end and format_range(comment)
      or string.format("%d-%d", comment.line_start, comment.line_end)
    table.insert(lines, string.format("%s## %s:%s%s", colors.header, comment.file, range, colors.reset))
    table.insert(lines, "")
  end

  -- Code context if available
  if comment.context_lines and #comment.context_lines > 0 then
    table.insert(lines, colors.section .. "### Context" .. colors.reset)
    table.insert(lines, "")
    table.insert(lines, colors.code .. "```" .. vim.fn.fnamemodify(comment.file, ":e"))
    for _, line in ipairs(comment.context_lines) do
      table.insert(lines, line)
    end
    table.insert(lines, "```" .. colors.reset)
    table.insert(lines, "")
  end

  -- Comment content
  table.insert(lines, colors.section .. "### Comment" .. colors.reset)
  table.insert(lines, "")
  -- Split comment by lines and add each line
  for line in comment.comment:gmatch("[^\n]+") do
    table.insert(lines, line)
  end

  return lines
end

--- Parse formatted content back to comments
---@param content string
---@return table[] comments
function M.parse(content)
  return M.parse_markdown(content)
end

--- Parse markdown content
---@param content string
---@return table[]
function M.parse_markdown(content)
  local lines = vim.split(content, "\n")
  local comments = {}
  local current_comment = nil
  local in_code_block = false
  local i = 1

  while i <= #lines do
    local line = lines[i]

    -- Skip empty lines and header
    if line:match("^#%s+Code Review") or line:match("^%*%*Date%*%*:") or line:match("^%*%*Total Comments%*%*:") then
      i = i + 1
      goto continue
    end

    -- File header
    if line:match("^##%s+(.+)") then
      -- Save any pending comment before starting new file
      if current_comment and current_comment.comment and current_comment.comment ~= "" then
        table.insert(comments, current_comment)
      end

      local file = line:match("^##%s+(.+)")
      current_comment = { file = file }
      i = i + 1
      goto continue
    end

    -- Line/Lines header
    if line:match("^###%s+Line[s]?%s+") then
      if current_comment and current_comment.comment then
        -- Save previous comment
        table.insert(comments, current_comment)
      end

      local range = line:match("^###%s+Lines?%s+(.+)$")
      local start, col_start, end_, col_end = range:match("^(%d+):(%d+)%-(%d+):(%d+)$")
      if not start then
        start, col_start, col_end = range:match("^(%d+):(%d+)%-(%d+)$")
        end_ = start
      end
      if not start then
        start, end_ = range:match("^(%d+)%-(%d+)$")
        start = start or range:match("^(%d+)$")
        end_ = end_ or start
      end
      if start then
        current_comment = {
          file = current_comment and current_comment.file,
          line_start = tonumber(start),
          line_end = tonumber(end_),
          col_start = tonumber(col_start),
          col_end = tonumber(col_end),
          context_lines = {},
          comment = "",
        }
      end
      i = i + 1
      goto continue
    end

    -- Code block markers
    if line == "```" then
      in_code_block = not in_code_block
      goto continue
    end

    -- Inside code block
    if in_code_block and current_comment then
      -- Parse context line (format: "123: code here")
      local num, code = line:match("^(%d+):%s(.*)$")
      if num and code then
        table.insert(current_comment.context_lines, code)
      end
      goto continue
    end

    -- Skip Time line
    if line:match("^%*%*Time%*%*:") then
      i = i + 1
      goto continue
    end

    -- Comment text
    if current_comment and not in_code_block and line ~= "" then
      if current_comment.comment == "" then
        current_comment.comment = line
      else
        current_comment.comment = current_comment.comment .. "\n" .. line
      end
    end

    ::continue::
    i = i + 1
  end

  -- Save last comment
  if current_comment and current_comment.comment and current_comment.comment ~= "" then
    table.insert(comments, current_comment)
  end

  -- Restore IDs and timestamps
  for i, comment in ipairs(comments) do
    comment.id = comment.id or (vim.fn.localtime() .. "_" .. i)
    comment.timestamp = comment.timestamp or os.time()
  end

  return comments
end

--- Save formatted content to file
---@param content string
---@param path string?
function M.save_to_file(content, path)
  local utils = require("code-review.utils")

  if not path then
    local save_dir = config.get("output.save_dir") or vim.fn.getcwd()
    local filename = utils.generate_filename("markdown")
    path = vim.fn.fnamemodify(save_dir .. "/" .. filename, ":p")
  else
    path = vim.fn.fnamemodify(path, ":p")
  end

  -- Ensure directory exists
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")

  -- Write file
  local file = io.open(path, "w")
  if not file then
    error("Failed to open file: " .. path)
  end

  file:write(content)
  file:close()

  vim.notify("Reviews saved to: " .. path)
end

return M
