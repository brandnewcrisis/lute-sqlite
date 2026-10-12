-- A small notes table: migrate, write, read, and a transfer done atomically.
--     lute run examples/notes.luau
local fs = require("@lute/fs")
local Sqlite = require("@sqlite")

if not fs.exists("./examples/data") then
	fs.mkdir("./examples/data")
end
local db = assert(Sqlite.open("./examples/data/notes.db"))

assert(db:migrate({
	[[
		CREATE TABLE players (user_id INTEGER PRIMARY KEY, name TEXT NOT NULL, marks INTEGER NOT NULL DEFAULT 0);
		CREATE TABLE notes (
			id INTEGER PRIMARY KEY,
			user_id INTEGER NOT NULL REFERENCES players (user_id),
			text TEXT NOT NULL,
			at INTEGER NOT NULL
		);
	]],
	"CREATE INDEX notes_user ON notes (user_id, at)",
}))

-- An upsert: the decision ("is there already a row?") is made in SQL.
for userId, name in { [5] = "eve", [6] = "sam" } do
	assert(db:exec([[
		INSERT INTO players (user_id, name, marks) VALUES (?, ?, 1000)
		ON CONFLICT (user_id) DO UPDATE SET name = excluded.name
	]], userId, name))
end

local made = assert(db:exec("INSERT INTO notes (user_id, text, at) VALUES (?, ?, ?)", 5, "Keep it in character; it's a role-play game", os.time()))
print(`note {made.lastInsertRowid} written`)

-- Both sides of a transfer, or neither.
local _, err = db:batch({
	{ "UPDATE players SET marks = marks - :amount WHERE user_id = :from", { amount = 250, from = 5 } },
	{ "UPDATE players SET marks = marks + :amount WHERE user_id = :to", { amount = 250, to = 6 } },
})
if err then
	print("transfer failed: " .. err)
end

for _, player in assert(db:query("SELECT name, marks FROM players ORDER BY marks DESC")) do
	print(player.name, player.marks)
end
print(`{assert(db:value("SELECT count(*) FROM notes WHERE user_id = ?", 5))} note(s) on eve`)
