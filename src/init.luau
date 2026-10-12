--!strict
--[[
	lute-sqlite -- SQLite for the Lute Luau runtime.

	    local Sqlite = require("@sqlite")
	    local db = assert(Sqlite.open("./data/panel.db"))

	    db:exec("INSERT INTO notes (user_id, text) VALUES (?, ?)", 156, "Keep it in character")
	    for _, note in assert(db:query("SELECT * FROM notes WHERE user_id = ?", 156)) do
	        print(note.text)
	    end

	Lute cannot load a SQLite library, so this drives the official sqlite3
	shell through process.run: one short process per call. See src/cli.luau
	for why that is safe and what it costs.
]]
local Bind = require("@sqlite/bind")
local Cli = require("@sqlite/cli")
local Database = require("@sqlite/database")
local Rows = require("@sqlite/rows")

local Sqlite = {}

export type Database = Database.Database
export type Row = Database.Row
export type Change = Database.Change
export type Outcome = Database.Outcome
export type Statement = Database.Statement

export type Options = {
	-- The sqlite3 executable, if it is not on PATH under that name.
	path: string?,
	-- How long a call waits for another process's lock. Default 5000.
	busyTimeoutMs: number?,
	-- Enforce FOREIGN KEY constraints (SQLite's own default is not to).
	-- Default true.
	foreignKeys: boolean?,
	-- Keep the file in write-ahead-log mode, where readers do not block the
	-- writer nor the writer them: what a program whose every call is a new
	-- connection wants. Default true.
	wal: boolean?,
}

-- A NULL that can sit in a list, where a bare nil cannot.
Sqlite.null = Bind.null

--[[
	Open a database file, creating it if it is not there.

	Nothing is held open: this checks that sqlite3 is present and recent
	enough, puts the file in WAL mode, and hands back the thing to call.
]]
function Sqlite.open(file: string, options: Options?): (Database.Database?, string?)
	local opts: Options = options or {}
	if file == "" or file == ":memory:" or file:sub(1, 5) == "file:" then
		-- Each call is its own process, so an in-memory database would be
		-- empty every time; a URI could ask for one, or for another file.
		return nil, "sqlite: give the path of a database file (an in-memory database cannot outlive a single call)"
	end
	if file:find("%z") then
		return nil, "sqlite: the database path contains a NUL byte"
	end
	-- "-x.db" would be read by sqlite3 as an option.
	if file:sub(1, 1) == "-" then
		file = "./" .. file
	end

	local path = opts.path or "sqlite3"
	local version, err = Cli.version(path)
	if version == nil then
		return nil, err
	end
	-- 3.37 is the first with -safe, which the safety of this package rests on.
	if version[1] < 3 or (version[1] == 3 and version[2] < 37) then
		return nil, `sqlite: {path} is version {version[1]}.{version[2]}.{version[3]}; 3.37 or later is needed`
	end

	local db = Database.new({
		path = path,
		file = file,
		busyTimeoutMs = opts.busyTimeoutMs or 5000,
		foreignKeys = opts.foreignKeys ~= false,
	})
	if opts.wal ~= false then
		-- Stored in the file, so this is a no-op on every open after the first.
		local ok, failure = db:script("PRAGMA journal_mode = WAL", false)
		if not ok then
			return nil, failure
		end
	end
	return db, nil
end

--[[
	A table or column name, quoted so that it is only ever a name.

	Values have placeholders; names do not. When one has to come from data (a
	sort column picked in a UI), check it against the names you expect AND
	pass it through this.
]]
function Sqlite.name(identifier: string): string
	if identifier:find("%z") then
		error("sqlite: a name cannot contain a NUL byte", 0)
	end
	return '"' .. identifier:gsub('"', '""') .. '"'
end

Sqlite.Bind = Bind
Sqlite.Rows = Rows
Sqlite.Cli = Cli
Sqlite.Database = Database

return Sqlite
