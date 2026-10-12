-- Lint for Lua 5.1+ constructs that would break (or silently differ) on WoW's Lua 5.0
local banned = {
  { "#",              "length operator '#' (5.0 uses table.getn)" },
  { "%.%.%.",         "'...' vararg expression (5.0 uses the implicit 'arg' table)" },
  { "string%.match",  "string.match (5.1+; use string.find with captures)" },
  { "string%.gmatch", "string.gmatch (5.1+; use string.gfind)" },
  { "[^%w_]select%s*%(", "select() (5.1+)" },
  { "math%.fmod",     "math.fmod (5.1+; use math.mod)" },
  { "math%.huge",     "math.huge (5.1+)" },
  { "table%.unpack",  "table.unpack (use unpack)" },
  { "table%.pack",    "table.pack (5.2+)" },
  { "xpcall",         "xpcall (not available in WoW 1.12)" },
  { "%%f%[",          "%f frontier pattern (5.1+)" },
  { "[^%w_]goto[^%w_]", "goto (5.2+)" },
  { "//",             "integer division (5.3)" },
  { "[^%w_]os%.",     "os library (not exposed in WoW)" },
  { "[^%w_]io%.",     "io library (not exposed in WoW)" },
  { "[^%w_]require%s*%(", "require (not in WoW)" },
}
local function strip(src)
  -- remove long strings/comments, then line comments, then quoted strings
  src = src:gsub("%-%-%[%[.-%]%]", "")
  src = src:gsub("%-%-[^\n]*", "")
  src = src:gsub("\\\\", "")
  src = src:gsub('"[^"\n]*"', '""')
  src = src:gsub("'[^'\n]*'", "''")
  return src
end
local bad = 0
for _, f in ipairs(arg) do
  local fh = assert(io.open(f, "rb")); local src = fh:read("a"); fh:close()
  local lineNo = 0
  local clean = strip(src)
  for line in (clean .. "\n"):gmatch("([^\n]*)\n") do
    lineNo = lineNo + 1
    for _, b in ipairs(banned) do
      if line:find(b[1]) then
        print(("%s:%d: %s"):format(f, lineNo, b[2])); bad = bad + 1
      end
    end
  end
end
print(bad == 0 and "lint5: clean" or ("lint5: " .. bad .. " issue(s)"))
os.exit(bad == 0 and 0 or 1)
