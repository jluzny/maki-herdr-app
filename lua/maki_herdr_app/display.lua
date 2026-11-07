local M = {}

function M.utf8_prefix(text, limit)
  limit = math.min(#text, limit)
  while limit > 0 and limit < #text and text:byte(limit + 1) >= 128 and text:byte(limit + 1) < 192 do
    limit = limit - 1
  end
  return text:sub(1, limit), limit
end

function M.compact(text, max)
  if #text <= max then
    return text
  end
  local marker = "\n[output truncated; incomplete text, not JSON]\n"
  local keep = max - #marker
  local head = math.floor(keep / 2)
  local prefix
  prefix, head = M.utf8_prefix(text, head)
  local tail = #text - (keep - math.floor(keep / 2)) + 1
  while tail <= #text and text:byte(tail) >= 128 and text:byte(tail) < 192 do
    tail = tail + 1
  end
  return prefix .. marker .. text:sub(tail)
end

function M.sanitize(text, inline)
  return text
    :gsub("\216\156", "?")
    :gsub("\226\128[\142\143\170-\174]", "?")
    :gsub("\226\129[\166-\169]", "?")
    :gsub("\194[\128-\159]", "?")
    :gsub(inline and "[%z\1-\31\127]" or "[%z\1-\9\11-\31\127]", "?")
end

function M.display_field(text, max)
  if text == "" then
    return "[empty]"
  end
  local shown, limit = M.utf8_prefix(text, max)
  return M.sanitize(shown, true) .. (limit < #text and " [truncated]" or "")
end

return M
