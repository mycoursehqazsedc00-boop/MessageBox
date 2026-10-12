-- Run every suite. Usage (from the tests/ directory):  lua run_all.lua
-- Needs Lua 5.2+ on the host (the *simulated* WoW environment is restricted to Lua 5.0).
local lua = (arg and arg[-1]) or "lua"
local suites = {
  { "lint (Lua 5.0 compatibility)", "lint5.lua ../Core.lua ../Utils.lua ../Logic.lua ../Theme.lua ../Components.lua ../UI.lua ../MessageBox.lua ../Compat.lua" },
  { "syntax",                        "syn.lua ../Core.lua ../Utils.lua ../Logic.lua ../Theme.lua ../Components.lua ../UI.lua ../MessageBox.lua ../Compat.lua" },
  { "repro of reported crash + fix", "t_repro.lua" },
  { "regression (A/B vs upstream)",  "t_regress.lua" },
  { "feature tests",                 "t_features.lua" },
  { "soak / fuzz",                   "t_soak.lua" },
}
local bad = 0
for _, s in ipairs(suites) do
  io.write(string.format("%-34s ", s[1])); io.flush()
  local p = io.popen(lua .. " " .. s[2] .. " 2>&1")
  local out = p:read("a"); local ok = p:close()
  if ok then print("PASS") else bad = bad + 1; print("FAIL"); print(out) end
end
print(bad == 0 and "\nALL SUITES PASSED" or ("\n" .. bad .. " SUITE(S) FAILED"))
print("(informational, not pass/fail: t_throttle.lua, t_trace.lua)")
os.exit(bad == 0 and 0 or 1)
