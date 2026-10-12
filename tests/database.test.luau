-- Integration test against a real sqlite3. Skips if there is none.
local fs = require("@lute/fs")
local process = require("@lute/process")
local task = require("@lute/task")
local Sqlite = require("@sqlite")

local fails = 0
local function check(n, c, got) if not c then fails += 1; print("FAIL " .. n .. (if got ~= nil then "  got: " .. tostring(got) else "")) else print("ok   " .. n) end end

local dir = "./tests/_scratch"
if not fs.exists(dir) then fs.mkdir(dir) end
for _, entry in fs.listdir(dir) do fs.remove(dir .. "/" .. entry.name) end
local file = dir .. "/test.db"

local db, why = Sqlite.open(file)
if db == nil then
	print("SKIP: " .. tostring(why))
	return
end
db = db :: any

check("an in-memory database is refused, with the reason", select(2, Sqlite.open(":memory:")) ~= nil and Sqlite.open(":memory:") == nil)
check("a missing sqlite3 is an error, not a raise", select(2, Sqlite.open(file, { path = "definitely-not-sqlite3" })) ~= nil)
check("the file is in WAL mode", db:value("PRAGMA journal_mode") == "wal")

check("schema", (db:script([[
	CREATE TABLE players (
		user_id INTEGER PRIMARY KEY,
		name TEXT NOT NULL UNIQUE,
		marks INTEGER NOT NULL DEFAULT 0,
		note TEXT,
		crest BLOB
	);
	CREATE TABLE kills (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id INTEGER NOT NULL REFERENCES players (user_id),
		at INTEGER NOT NULL
	);
	CREATE TABLE log (line TEXT);
	CREATE TRIGGER on_kill AFTER INSERT ON kills BEGIN
		INSERT INTO log (line) VALUES ('kill by ' || NEW.user_id);
		UPDATE players SET marks = marks + 10 WHERE user_id = NEW.user_id;
	END;
]])))

-- writing
local made, err = db:exec("INSERT INTO players (user_id, name, marks) VALUES (?, ?, ?)", 5, "eve", 1500)
check("insert", made ~= nil and made.changes == 1 and made.lastInsertRowid == 5, err)
check("insert, named", (db:exec("INSERT INTO players (user_id, name) VALUES (:id, :name)", { id = 6, name = "sam" })) ~= nil)
local updated = db:exec("UPDATE players SET marks = marks + 1")
check("update counts every row", updated.changes == 2)
check("an update that matches nothing changed nothing", db:exec("UPDATE players SET marks = 0 WHERE user_id = ?", 404).changes == 0)

-- reading
local rows = db:query("SELECT user_id, name, marks, note FROM players ORDER BY user_id")
check("query", #rows == 2 and rows[1].name == "eve" and rows[1].marks == 1501 and rows[2].user_id == 6)
check("NULL is absent from the row", rows[1].note == nil)
check("first", db:first("SELECT name FROM players WHERE user_id = ?", 6).name == "sam")
local none, noneErr = db:first("SELECT name FROM players WHERE user_id = ?", 404)
check("first with no row is nil and no error", none == nil and noneErr == nil)
check("value", db:value("SELECT count(*) FROM players") == 2)
check("value with no row", db:value("SELECT name FROM players WHERE user_id = ?", 404) == nil)
check("a query with no rows is an empty list", #db:query("SELECT * FROM players WHERE 0") == 0)
check("RETURNING comes back as rows", db:query("UPDATE players SET marks = marks WHERE user_id = ? RETURNING name", 5)[1].name == "eve")

-- failures are values
local bad, badErr = db:exec("INSERT INTO players (user_id, name) VALUES (?, ?)", 5, "again")
check("a constraint failure is (nil, message)", bad == nil and badErr:find("UNIQUE constraint failed", 1, true) ~= nil, badErr)
check("so is bad SQL", select(2, db:query("SELEC 1")) ~= nil)
check("foreign keys are enforced", select(2, db:exec("INSERT INTO kills (user_id, at) VALUES (?, ?)", 999, 1)) ~= nil)
local loose = Sqlite.open(file, { foreignKeys = false }) :: any
check("unless turned off", loose:exec("INSERT INTO kills (user_id, at) VALUES (?, ?)", 999, 1) ~= nil)
loose:exec("DELETE FROM kills")
loose:exec("DELETE FROM log")

-- every kind of value, there and back
local nasty = [[a;rm -rf /;b "quoted" 'single' $(whoami) `id` \ %s -- /* ]] .. "\n.shell echo pwned\n\ttab \r\n \1\127 ünïcödé 🙂 '); DROP TABLE players; --"
db:exec("INSERT INTO players (user_id, name, note, crest) VALUES (?, ?, ?, ?)", 7, nasty, "", buffer.fromstring("\0\1\255'\n"))
local back = db:first("SELECT name, note, crest, typeof(name) AS kind FROM players WHERE user_id = ?", 7)
check("a hostile string round-trips byte for byte", back.name == nasty, back.name)
check("and is still text", back.kind == "text")
check("and can be searched for", db:value("SELECT user_id FROM players WHERE name = ?", nasty) == 7)
check("the table it tried to drop is still there", db:value("SELECT count(*) FROM players") == 3)
check("an empty string is not NULL", back.note == "")
check("a blob round-trips", typeof(back.crest) == "buffer" and buffer.tostring(back.crest) == "\0\1\255'\n")
local numbers, numbersErr = db:first("SELECT ? AS whole, ? AS fraction, ? AS big, ? AS huge, ? AS yes, ? AS missing", 11494693418, 0.1, 2 ^ 53 - 1, math.huge, true, nil)
check("numbers round-trip", numbers ~= nil and numbers.whole == 11494693418 and numbers.fraction == 0.1 and numbers.big == 2 ^ 53 - 1 and numbers.huge == math.huge and numbers.yes == 1 and numbers.missing == nil, numbersErr)
check("a string with a NUL byte is refused before anything is sent", not pcall(db.exec, db, "UPDATE players SET note = ? WHERE user_id = 5", "a\0b"))
check("an integer past 2^53 comes back exact, as text", db:value("SELECT 9007199254740993") == "9007199254740993")
check("LIKE with a value", db:value("SELECT count(*) FROM players WHERE name LIKE ?", "ev%") == 1)

-- batch: one process, one transaction
local outcomes, batchErr = db:batch({
	{ "INSERT INTO kills (user_id, at) VALUES (?, ?)", 5, 100 },
	{ "INSERT INTO kills (user_id, at) VALUES (:who, :at)", { who = 6, at = 101 } },
	"SELECT count(*) AS n FROM kills",
	{ "UPDATE players SET note = ? WHERE user_id = ?", Sqlite.null, 5 },
})
check("batch", outcomes ~= nil and #outcomes == 4, batchErr)
check("each statement reports its own rows", outcomes[3].rows[1].n == 2 and #outcomes[1].rows == 0)
check("changes include what a trigger did", outcomes[1].changes == 3 and outcomes[3].changes == 0 and outcomes[4].changes == 1, outcomes[1].changes)
check("the trigger ran", db:value("SELECT marks FROM players WHERE user_id = ?", 5) == 1511 and db:value("SELECT count(*) FROM log") == 2)
check("last insert rowid per statement", outcomes[1].lastInsertRowid ~= outcomes[2].lastInsertRowid)

local before = db:value("SELECT count(*) FROM kills")
local failed, failedErr = db:batch({
	{ "INSERT INTO kills (user_id, at) VALUES (?, ?)", 5, 200 },
	{ "INSERT INTO kills (user_id, at) VALUES (?, ?)", 5, 201 },
	{ "INSERT INTO players (user_id, name) VALUES (?, ?)", 5, "duplicate" },
	{ "INSERT INTO kills (user_id, at) VALUES (?, ?)", 5, 202 },
})
check("a batch that fails reports it", failed == nil and failedErr ~= nil)
check("and none of it happened", db:value("SELECT count(*) FROM kills") == before)
check("an empty batch is nothing", #db:batch({}) == 0)

local bulk = {}
for index = 1, 3000 do
	table.insert(bulk, { "INSERT INTO log (line) VALUES (?)", `line {index} ` .. string.rep("x", 200) })
end
local started = os.clock()
check("3000 inserts in one batch (too long for a command line, so through a file)", db:batch(bulk) ~= nil)
check("all there", db:value("SELECT count(*) FROM log") == 3002)
print(string.format("     (%.0f ms)", (os.clock() - started) * 1000))
local leftovers = 0
for _, entry in fs.listdir(dir) do
	if entry.name:find(".lute-sqlite-", 1, true) then leftovers += 1 end
end
check("the file it went through is gone", leftovers == 0)

local large = buffer.create(300_000)
for index = 0, 299_999 do buffer.writeu8(large, index, index % 251) end
check("a 300 KB blob in one statement", db:exec("UPDATE players SET crest = ? WHERE user_id = ?", large, 6) ~= nil)
check("comes back whole", buffer.tostring(db:value("SELECT crest FROM players WHERE user_id = ?", 6)) == buffer.tostring(large))

-- nothing but SQL, and nothing outside the database
check("a dot-command is refused", select(2, db:script(".shell echo pwned")) ~= nil)
check("a dot-command is refused after spaces too", select(2, db:exec("  .shell echo pwned")) ~= nil)
check("ATTACH is refused (safe mode)", select(2, db:exec("ATTACH DATABASE ? AS other", dir .. "/other.db")) ~= nil and not fs.exists(dir .. "/other.db"))
check("so is writing a file from SQL", select(2, db:query("SELECT writefile(?, ?)", dir .. "/pwned.txt", "x")) ~= nil and not fs.exists(dir .. "/pwned.txt"))
check("and loading an extension", select(2, db:query("SELECT load_extension(?)", "/tmp/evil")) ~= nil)
check("a dot at the start of a line inside a script is SQL, not a command", select(2, db:script("SELECT 1;\n.shell echo pwned")) ~= nil)

-- names
check("a quoted name", Sqlite.name('odd "name"') == '"odd ""name"""')
db:script(`CREATE TABLE {Sqlite.name("odd; table")} ({Sqlite.name('a "col"')} TEXT)`)
check("a quoted name works as a name", db:exec(`INSERT INTO {Sqlite.name("odd; table")} ({Sqlite.name('a "col"')}) VALUES (?)`, "x") ~= nil)

-- migrations
local fresh = Sqlite.open(dir .. "/migrate.db") :: any
local history = {
	"CREATE TABLE a (x INTEGER)",
	"ALTER TABLE a ADD COLUMN y TEXT; CREATE INDEX a_y ON a (y)",
}
check("migrate from nothing", fresh:migrate(history) == 2)
check("running it again does nothing", fresh:migrate(history) == 2)
table.insert(history, "CREATE TABLE b (z INTEGER); THIS IS NOT SQL")
local version, migrateErr = fresh:migrate(history)
check("a broken migration says which", version == nil and migrateErr:find("migration 3", 1, true) ~= nil, migrateErr)
check("and leaves no half of itself behind", fresh:value("SELECT count(*) FROM sqlite_master WHERE name = 'b'") == 0 and fresh:value("PRAGMA user_version") == 2)
history[3] = "CREATE TABLE b (z INTEGER)"
check("fixed, it applies", fresh:migrate(history) == 3)

-- waiting for another writer, and not blocking the scheduler while it does
local impatient = Sqlite.open(file, { busyTimeoutMs = 50 }) :: any
local ticks = 0
local holderDone = false
task.spawn(function()
	-- Another process holding the write lock for about a second.
	process.run({ "sqlite3", file, "BEGIN IMMEDIATE", "SELECT count(*) FROM (WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 6000000) SELECT x FROM c)", "COMMIT" })
	holderDone = true
end)
task.spawn(function()
	while not holderDone do task.wait(0.02); ticks += 1 end
end)
task.wait(0.15)
if not holderDone then
	local _, busyErr = impatient:exec("UPDATE players SET marks = marks WHERE user_id = 5")
	check("a locked database is an error once the wait runs out", busyErr ~= nil and busyErr:find("locked", 1, true) ~= nil, busyErr)
	check("a reader is not shut out by the writer (WAL)", db:value("SELECT count(*) FROM players") == 3)
	check("a patient writer waits its turn", db:exec("UPDATE players SET marks = marks WHERE user_id = 5") ~= nil)
	check("other tasks ran while it waited", ticks > 3, ticks)
else
	print("     (the lock holder finished too quickly to test waiting)")
end

print(if fails == 0 then "\nALL PASS" else "\n" .. fails .. " FAILURES")
