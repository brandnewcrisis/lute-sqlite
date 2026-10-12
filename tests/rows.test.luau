-- Reading the shell's quote-mode output, in both of its dialects. No
-- database needed.
local Rows = require("@sqlite/rows")

local fails = 0
local function check(n, c, got) if not c then fails += 1; print("FAIL " .. n .. (if got ~= nil then "  got: " .. tostring(got) else "")) else print("ok   " .. n) end end
local M = "--lute-sqlite--"
local function one(text) return Rows.parse(text .. M .. "\n", M)[1] end

local r = one("'a','b'\n1,'x'\n2,'y'\n")
check("columns in order", r.columns[1] == "a" and r.columns[2] == "b" and #r.columns == 2)
check("rows by column name", #r.rows == 2 and r.rows[1].a == 1 and r.rows[2].b == "y")

r = one("")
check("nothing printed is no rows and no columns", #r.rows == 0 and #r.columns == 0)

r = one("'a','b','c'\nNULL,'NULL',''\n")
check("NULL is absent", r.rows[1].a == nil)
check("'NULL' is a string", r.rows[1].b == "NULL")
check("'' is an empty string, not NULL", r.rows[1].c == "")

r = one("'s'\n'it''s, \"quoted\"'\n")
check("doubled quote, comma and double quotes inside a string", r.rows[1].s == 'it\'s, "quoted"', r.rows[1].s)

r = one("'s','n'\n'line one\nline two',5\n")
check("a raw line break inside a string (shells before 3.50)", r.rows[1].s == "line one\nline two" and r.rows[1].n == 5)

r = one("'s','n'\nunistr('line one\\u000aline two'),5\n")
check("the same string from a 3.50+ shell", r.rows[1].s == "line one\nline two" and r.rows[1].n == 5)

r = one("'s'\nunistr('back\\\\slash\\u0009tab it''s \\u0000 nul')\n")
check("unistr: backslash, tab, quote, NUL", r.rows[1].s == "back\\slash\ttab it's \0 nul", r.rows[1].s)

r = one("'s'\n'plain\\u000a'\n")
check("a backslash outside unistr is only a backslash", r.rows[1].s == "plain\\u000a")

r = one("'s'\n'" .. M .. "'\n")
check("the marker as a value is a value", r.rows[1].s == M)
r = one("'s'\n'x\n" .. M .. "\ny'\n")
check("the marker on its own line inside a string is still the string", r.rows[1].s == "x\n" .. M .. "\ny", r.rows[1].s)

r = one("'i','f','big','neg','e'\n42,0.30000000000000004,9007199254740993,-3,1.0e+21\n")
check("integer", r.rows[1].i == 42 and r.rows[1].neg == -3)
check("real, to the last digit", r.rows[1].f == 0.1 + 0.2)
check("an integer too big for a double stays exact, as text", r.rows[1].big == "9007199254740993")
check("exponent form", r.rows[1].e == 1e21)

r = one("'a','b','c','d'\n9.0e+999,-9.0e+999,Inf,-Inf\n")
check("infinity, either spelling", r.rows[1].a == math.huge and r.rows[1].b == -math.huge and r.rows[1].c == math.huge and r.rows[1].d == -math.huge)

r = one("'b','e'\nX'00ff41',X''\n")
check("a blob is a buffer", typeof(r.rows[1].b) == "buffer" and buffer.tostring(r.rows[1].b) == "\0\255A")
check("an empty blob is an empty buffer", typeof(r.rows[1].e) == "buffer" and buffer.len(r.rows[1].e) == 0)

r = one("'we,ird ''col'\n1\n")
check("a column name with a comma and a quote", r.columns[1] == "we,ird 'col" and r.rows[1]["we,ird 'col"] == 1)

local many = Rows.parse("'a'\n1\n" .. M .. "\n" .. M .. "\n'b'\n'x'\n'y'\n" .. M .. "\n", M)
check("three results, the middle one empty", #many == 3 and many[1].rows[1].a == 1 and #many[2].rows == 0 and #many[3].rows == 2)

r = one("'a','b'\r\n1,'x'\r\n")
check("CRLF line endings", #r.rows == 1 and r.rows[1].a == 1 and r.rows[1].b == "x")

check("garbage raises, not misreads", not pcall(Rows.parse, "'a'\nwhat\n", M))
check("output cut off inside a string raises", not pcall(Rows.parse, "'a'\n'unfinished", M))

print(if fails == 0 then "\nALL PASS" else "\n" .. fails .. " FAILURES")
