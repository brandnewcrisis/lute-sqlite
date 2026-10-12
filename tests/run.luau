local fs = require("@lute/fs")
local process = require("@lute/process")
local names = {}
for _, entry in fs.listdir("./tests") do
	local name = (entry :: any).name or tostring(entry)
	if name:match("%.test%.luau$") then table.insert(names, name) end
end
table.sort(names)
local failed = {}
for _, name in names do
	print(`\n=== {name} ===`)
	local r = process.run({ process.execPath(), "run", `./tests/{name}` })
	print((r.stdout:gsub("\n$", "")))
	if r.stderr ~= "" then print(r.stderr) end
	if not r.ok or r.stdout:find("FAILURES") then table.insert(failed, name) end
end
print("\n" .. string.rep("-", 40))
if #failed == 0 then print("ALL " .. #names .. " SUITES PASS") else print("FAILED: " .. table.concat(failed, ", ")) end
