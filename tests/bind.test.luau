-- Values into SQL text, and placeholders found (or left alone). No database
-- needed: this is the part that has to be right on paper.
local Bind = require("@sqlite/bind")

local fails = 0
local function check(n, c, got) if not c then fails += 1; print("FAIL " .. n .. (if got ~= nil then "  got: " .. tostring(got) else "")) else print("ok   " .. n) end end
local function raises(n, f, needle)
	local ok, err = pcall(f)
	check(n, not ok and tostring(err):find(needle, 1, true) ~= nil, if ok then "no error" else err)
end
local function apply(sql, ...) return Bind.apply(sql, Bind.pack(...)) end

-- literals
check("nil is NULL", Bind.literal(nil) == "NULL")
check("the null marker is NULL", Bind.literal(Bind.null) == "NULL")
check("true is 1", Bind.literal(true) == "1" and Bind.literal(false) == "0")
check("a whole number has no decimal point", Bind.literal(42) == "42" and Bind.literal(-7) == "-7")
check("a big id keeps every digit", Bind.literal(11494693418) == "11494693418")
check("a fraction round-trips", tonumber(Bind.literal(0.1)) == 0.1 and tonumber(Bind.literal(1 / 3)) == 1 / 3)
check("past 2^53 it is a real", Bind.literal(2 ^ 60):find("e", 1, true) ~= nil)
check("infinity", Bind.literal(math.huge) == "9e999" and Bind.literal(-math.huge) == "-9e999")
raises("NaN is refused", function() Bind.literal(0 / 0) end, "NaN")
raises("a table is refused", function() Bind.literal({}) end, "table")
check("a plain string is quoted", Bind.literal("Marta Vogel") == "'Marta Vogel'")
check("a quote is doubled", Bind.literal("it's") == "'it''s'")
check("backslashes and double quotes are just characters", Bind.literal([[a\"b]]) == [['a\"b']])
check("the classic", Bind.literal("'; DROP TABLE players; --") == "'''; DROP TABLE players; --'")
check("a newline never appears as text", Bind.literal("a\nb") == "CAST(X'610A62' AS TEXT)")
check("nor a tab", Bind.literal("\t") == "CAST(X'09' AS TEXT)")
raises("a string with a NUL is refused, not stored to come back short", function() Bind.literal("a\0b") end, "NUL")
check("UTF-8 stays readable", Bind.literal("Höß 🙂") == "'Höß 🙂'")
check("an empty string is not NULL", Bind.literal("") == "''")
check("a buffer is a blob", Bind.literal(buffer.fromstring("\0\255A")) == "X'00FF41'")

-- placeholders
check("positional", apply("SELECT ?, ?", 1, "x") == "SELECT 1, 'x'")
check("a nil in the middle is NULL", apply("SELECT ?, ?, ?", 1, nil, 3) == "SELECT 1, NULL, 3")
check("a trailing nil counts", apply("SELECT ?, ?", 1, nil) == "SELECT 1, NULL")
check("numbered", apply("SELECT ?2, ?1, ?2", "a", "b") == "SELECT 'b', 'a', 'b'")
check("? after ?N takes the one after it", apply("SELECT ?2, ?, ?1", "a", "b", "c") == "SELECT 'b', 'c', 'a'")
check("one list instead of several arguments", apply("SELECT ?, ?", { 1, "x" }) == "SELECT 1, 'x'")
check("named, all three spellings", apply("SELECT :a, @b, $c", { a = 1, b = 2, c = 3 }) == "SELECT 1, 2, 3")
check("a named value used twice", apply("SELECT :a, :a", { a = "x" }) == "SELECT 'x', 'x'")
check("a named value called n", apply("SELECT :n", { n = 5 }) == "SELECT 5")
check("an absent named value is NULL", apply("SELECT :a, :b", { a = 1, b = Bind.null }) == "SELECT 1, NULL")
check("no values, no placeholders", apply("SELECT 1") == "SELECT 1")
check("a lone buffer is a value", apply("SELECT ?", buffer.fromstring("A")) == "SELECT X'41'")
check("a lone null marker is a value", apply("SELECT ?", Bind.null) == "SELECT NULL")

-- what must NOT be taken for a placeholder
check("? in a string", apply("SELECT 'what?', ?", 1) == "SELECT 'what?', 1")
check("? after an escaped quote in a string", apply("SELECT 'it''s ?', ?", 1) == "SELECT 'it''s ?', 1")
check(":name in a string", apply("SELECT '12:30:name', ?", 1) == "SELECT '12:30:name', 1")
check("? in a quoted name", apply('SELECT "odd?col", ? FROM t', 1) == 'SELECT "odd?col", 1 FROM t')
check("? in a bracketed name", apply("SELECT [odd?col], ? FROM t", 1) == "SELECT [odd?col], 1 FROM t")
check("? in a backticked name", apply("SELECT `odd?col`, ? FROM t", 1) == "SELECT `odd?col`, 1 FROM t")
check("? in a line comment", apply("SELECT ? -- really?\n", 1) == "SELECT 1 -- really?\n")
check("? in a block comment", apply("SELECT /* ? */ ?", 1) == "SELECT /* ? */ 1")
check("minus and divide are not comments", apply("SELECT ? - 1, ? / 2", 5, 6) == "SELECT 5 - 1, 6 / 2")
check("the JSON arrow is left alone", apply("SELECT data ->> '$.a' FROM t WHERE id = ?", 1) == "SELECT data ->> '$.a' FROM t WHERE id = 1")
check("a value is not scanned again", apply("SELECT ?, ?", "?", ":x") == "SELECT '?', ':x'")

-- mistakes are loud
raises("too few values", function() apply("SELECT ?, ?", 1) end, "needs value 2")
raises("too many values", function() apply("SELECT ?", 1, 2) end, "no placeholder for value 2")
raises("values but no placeholders", function() apply("SELECT 1", 1) end, "no placeholder")
raises("placeholders but no values", function() apply("SELECT ?") end, "needs value 1")
raises("a named value nothing uses", function() apply("SELECT :a", { a = 1, typo = 2 }) end, "typo")
raises("? with named values", function() apply("SELECT ?", { a = 1 }) end, "named")
raises(":name with positional values", function() apply("SELECT :a", 1) end, "named")

-- one statement per call
check("a trailing semicolon is fine", apply("SELECT 1;") == "SELECT 1;")
check("so is a trailing comment", apply("SELECT 1; -- done\n  ") == "SELECT 1; -- done\n  ")
check("a semicolon in a string is not a second statement", apply("SELECT 'a;b'") == "SELECT 'a;b'")
raises("a second statement is refused", function() apply("SELECT 1; DROP TABLE t") end, "one statement")
raises("even through a value-free call", function() apply("DELETE FROM a; DELETE FROM b;") end, "one statement")

print(if fails == 0 then "\nALL PASS" else "\n" .. fails .. " FAILURES")
