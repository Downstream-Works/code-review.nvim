local M = {}

local formatter = require("code-review.formatter")

--- Record a comment's original preview structure and location
---@param snapshot table
---@param lines string[]
---@param section_start number
---@param file string
---@param comment table
local function record_preview_section(snapshot, lines, section_start, file, comment)
  local location_line = #vim.split(table.concat(lines, "\n", 1, section_start - 1), "\n") + 1
  snapshot.locations[location_line] = true

  table.insert(snapshot.sections, {
    file = file,
    structure = table.concat(lines, "\n", section_start) .. "\n",
    location = lines[section_start],
    time = lines[section_start + 1],
    body = comment.comment,
    comment = vim.deepcopy(comment),
  })
end

--- Format a detailed editable preview with its original structure and comments
---@param comments table[]
---@return string, table
function M.format(comments)
  local snapshot = {
    comments = vim.deepcopy(comments),
    sections = {},
    files = {},
    locations = {},
  }

  local content = formatter._format_markdown(comments, function(lines, section_start, file, comment)
    if comment then
      record_preview_section(snapshot, lines, section_start, file, comment)
    elseif file then
      snapshot.files[lines[section_start]] = file
    else
      snapshot.header = table.concat(lines, "\n")
    end
  end)
  snapshot.content = content

  return content, snapshot
end

--- Assign each parsed section to an original comment
---@param sections table[]
local function assign_original_comments(sections)
  -- Match unchanged bodies first to retain identities shared by equal structures.
  local used = {}
  for _, section in ipairs(sections) do
    for _, candidate in ipairs(section.candidates) do
      if not used[candidate] and candidate.body == section.body then
        section.original = candidate
        used[candidate] = true
        break
      end
    end
  end

  for _, section in ipairs(sections) do
    if not section.original then
      for _, candidate in ipairs(section.candidates) do
        if not used[candidate] then
          section.original = candidate
          break
        end
      end
      if not section.original then
        error("Duplicate preview comment section")
      end
      used[section.original] = true
    end
  end
end

--- Restore comment metadata with edited bodies
---@param sections table[]
---@return table[]
local function restore_comments(sections)
  assign_original_comments(sections)

  local comments = {}
  for _, section in ipairs(sections) do
    local comment = vim.deepcopy(section.original.comment)
    if section.body ~= section.original.body then
      comment.comment = section.body
    end
    table.insert(comments, comment)
  end

  return comments
end

--- Validate the review header and split the remaining preview
---@param content string
---@param snapshot table
---@return string[]|nil
local function split_preview_content(content, snapshot)
  if content:sub(1, #snapshot.header) ~= snapshot.header then
    error("Preview review header was changed")
  end

  local remaining = content:sub(#snapshot.header + 1)
  if remaining == "" then
    return nil
  end

  if remaining:sub(1, 1) ~= "\n" then
    error("Preview review header was changed")
  end

  return vim.split(remaining:sub(2), "\n")
end

--- Locate original section headers retained in the edited preview
---@param content string
---@param snapshot table
---@return table, table
local function retained_preview_structure(content, snapshot)
  local retained_locations, retained_times = {}, {}
  local old_line, new_line = 1, 1
  local header_lines = #vim.split(snapshot.header, "\n")

  --- Map unchanged original lines to edited positions relative to the review header
  ---@param last number
  local function retain_until(last)
    while old_line < last do
      if snapshot.locations[old_line] then
        retained_locations[new_line - header_lines] = true
      elseif snapshot.locations[old_line - 1] then
        retained_times[new_line - header_lines] = true
      end
      old_line, new_line = old_line + 1, new_line + 1
    end
  end

  for _, change in ipairs(vim.diff(snapshot.content, content, { result_type = "indices" })) do
    local old_start = change[1] + (change[2] == 0 and 1 or 0)
    local new_start = change[3] + (change[4] == 0 and 1 or 0)
    retain_until(old_start)
    old_line, new_line = old_start + change[2], new_start + change[4]
  end

  retain_until(#vim.split(snapshot.content, "\n") + 1)

  return retained_locations, retained_times
end

--- Finish the current section and reset its body accumulator
---@param sections table[]
---@param current table|nil
---@param body string[]
---@return string[]
local function finish_preview_section(sections, current, body)
  if not current then
    return body
  end

  if body[#body] ~= "" then
    error("Preview section separator was changed")
  end

  table.remove(body)
  current.body = table.concat(body, "\n")
  table.insert(sections, current)

  return {}
end

--- Recognize section boundaries from retained lines or original structure
---@param lines string[]
---@param index number
---@param snapshot table
---@param retained_locations table
---@param retained_times table
---@return boolean
local function is_preview_section(lines, index, snapshot, retained_locations, retained_times)
  if retained_locations[index] or retained_times[index] then
    return true
  end

  local section_content = table.concat(lines, "\n", index)
  for _, section in ipairs(snapshot.sections) do
    if section_content:sub(1, #section.structure) == section.structure then
      return true
    end
  end

  return false
end

--- Find original sections matching the current file and structure
---@param lines string[]
---@param index number
---@param file string|nil
---@param snapshot table
---@return table[], string
local function match_preview_structure(lines, index, file, snapshot)
  local candidates = {}
  local section_content = table.concat(lines, "\n", index)
  local structure

  -- Prefer the longest matching structure and keep candidates with that structure.
  for _, section in ipairs(snapshot.sections) do
    if section.file == file and section_content:sub(1, #section.structure) == section.structure then
      if not structure or #section.structure > #structure then
        candidates = { section }
        structure = section.structure
      elseif section.structure == structure then
        table.insert(candidates, section)
      end
    end
  end

  if not structure then
    error("Preview comment structure was changed")
  end

  return candidates, structure
end

--- Collect comment sections under their original file headings
---@param lines string[]
---@param snapshot table
---@param retained_locations table
---@param retained_times table
---@return table[]
local function collect_preview_sections(lines, snapshot, retained_locations, retained_times)
  local sections = {}
  local file, current
  local body = {}

  --- Check for a section boundary at the given preview line
  ---@param index number
  ---@return boolean
  local function is_section(index)
    return is_preview_section(lines, index, snapshot, retained_locations, retained_times)
  end

  local i = 1
  while i <= #lines do
    local line = lines[i]
    -- Recognize file headings from section boundaries and known trailing headings.
    local file_header = line:match("^## ")
      and (not current or is_section(i + 1) or is_section(i + 2) or (snapshot.files[line] and i + 1 == #lines))

    if file_header then
      body = finish_preview_section(sections, current, body)
      current = nil
      if not snapshot.files[line] or lines[i + 1] ~= "" then
        error("Preview file heading was changed")
      end
      file = snapshot.files[line]
      i = i + 2
    elseif is_section(i) then
      body = finish_preview_section(sections, current, body)
      local candidates, structure = match_preview_structure(lines, i, file, snapshot)
      current = { candidates = candidates }
      i = i + #vim.split(structure, "\n") - 1
    elseif current then
      table.insert(body, line)
      i = i + 1
    elseif i == #lines and line == "" then
      break
    else
      error("Preview comment structure was changed")
    end
  end

  finish_preview_section(sections, current, body)

  return sections
end

--- Parse edited bodies using the preview's original structural text
---@param content string
---@param snapshot table
---@return table[]
function M.parse(content, snapshot)
  local lines = split_preview_content(content, snapshot)
  if not lines then
    return {}
  end

  local retained_locations, retained_times = retained_preview_structure(content, snapshot)
  local sections = collect_preview_sections(lines, snapshot, retained_locations, retained_times)

  return restore_comments(sections)
end

return M
