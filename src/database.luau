--!strict
--[[
	The database surface.

	Every method answers `(value, error)`. A constraint that fails, a locked
	file, a table that is not there: those are ordinary conditions for a
	long-running program and belong at the call site, so none of them raise.
	What does raise is a mistake in the call itself -- three values for two
	placeholders, a table where a value should be -- because that is a bug,
	and a bug should be loud the first time the line runs.

	One call is one process is one connection. See @sqlite/cli for what that
	means; the short version is that `batch` is how to do several things at
	once, and how to do them atomically.
]]
local Bind = require("@sqlite/bind")
local Cli = require("@sqlite/cli")
local Rows = require("@sqlite/rows")

local Database = {}
Database.__index = Database

export type Database = typeof(setmetatable({} :: {
	config: Cli.Config,
	file: string,
}, Database))

export type Row = Rows.Row

-- What a statement that writes did.
export type Change = {
	-- Rows inserted, updated or deleted, including by triggers it fired.
	changes: number,
	-- The rowid of the last row inserted on this connection; 0 if none was.
	lastInsertRowid: number,
}

-- One statement's whole result, as `batch` reports it.
export type Outcome = Change & {
	columns: { string },
	rows: { Row },
}

-- A statement for `batch`: SQL alone, or SQL followed by its values --
-- `{ sql, 1, "x" }`, `{ sql, { 1, "x" } }` or `{ sql, { name = "x" } }`.
export type Statement = string | { any }

export type BatchOptions = {
	-- "immediate" (the default) takes the write lock up front, so the batch
	-- cannot get half way and find another writer in its path. "deferred"
	-- suits a batch that only reads; "exclusive" also shuts readers out.
	mode: ("immediate" | "deferred" | "exclusive")?,
}

-- Asked after every statement. total_changes() counts from when the
-- connection opened, so the difference between two readings is what the
-- statement between them changed (changes() would repeat a stale count
-- after a SELECT).
local TALLY = "SELECT total_changes() AS total, last_insert_rowid() AS rowid"

function Database.new(config: Cli.Config): Database
	return setmetatable({ config = config, file = config.file }, Database)
end

local function run(self: Database, statements: { string }, transaction: string?): ({ Outcome }?, string?)
	local commands: { string } = {}
	if transaction then
		table.insert(commands, "BEGIN " .. transaction)
	end
	for _, sql in statements do
		table.insert(commands, sql)
		table.insert(commands, Cli.PRINT)
		table.insert(commands, TALLY)
		table.insert(commands, Cli.PRINT)
	end
	if transaction then
		table.insert(commands, "COMMIT")
	end

	local output, err = Cli.run(self.config, commands)
	if output == nil then
		return nil, err
	end
	local parsed, results = pcall(Rows.parse, output, Cli.MARKER)
	if not parsed then
		return nil, tostring(results)
	end
	if #results ~= #statements * 2 then
		return nil, `sqlite: expected {#statements * 2} results from the shell and read {#results}`
	end

	local outcomes: { Outcome } = {}
	local before = 0
	for index = 1, #statements do
		local result = results[index * 2 - 1]
		local tally = results[index * 2].rows[1]
		table.insert(outcomes, {
			columns = result.columns,
			rows = result.rows,
			changes = tally.total - before,
			lastInsertRowid = tally.rowid,
		})
		before = tally.total
	end
	return outcomes, nil
end

-- Every row the statement returns, each as `{ column = value }`. A NULL is
-- simply absent from its row.
function Database.query(self: Database, sql: string, ...: any): ({ Row }?, string?)
	local outcomes, err = run(self, { Bind.apply(sql, Bind.pack(...)) })
	if outcomes == nil then
		return nil, err
	end
	return outcomes[1].rows, nil
end

-- The first row, or nil when there is none. (nil, nil) is "no such row";
-- (nil, "...") is a failure.
function Database.first(self: Database, sql: string, ...: any): (Row?, string?)
	local outcomes, err = run(self, { Bind.apply(sql, Bind.pack(...)) })
	if outcomes == nil then
		return nil, err
	end
	return outcomes[1].rows[1], nil
end

-- The first column of the first row: a count, a setting, an id.
function Database.value(self: Database, sql: string, ...: any): (any, string?)
	local outcomes, err = run(self, { Bind.apply(sql, Bind.pack(...)) })
	if outcomes == nil then
		return nil, err
	end
	local row = outcomes[1].rows[1]
	if row == nil then
		return nil, nil
	end
	return row[outcomes[1].columns[1]], nil
end

-- Run a statement for what it does, not what it returns.
function Database.exec(self: Database, sql: string, ...: any): (Change?, string?)
	local outcomes, err = run(self, { Bind.apply(sql, Bind.pack(...)) })
	if outcomes == nil then
		return nil, err
	end
	return { changes = outcomes[1].changes, lastInsertRowid = outcomes[1].lastInsertRowid }, nil
end

--[[
	Several statements in one process and ONE transaction: all of them
	happen, or (if any fails) none do.

	    db:batch({
	        { "UPDATE purse SET marks = marks - ? WHERE user_id = ?", 250, 5 },
	        { "UPDATE purse SET marks = marks + ? WHERE user_id = ?", 250, 6 },
	        "DELETE FROM pending WHERE done = 1",
	    })

	This is also the fast way to write many rows: a thousand inserts here are
	one spawn, not a thousand. What it cannot do is read a row, decide in Luau,
	and write, all inside the transaction: the connection does not live that
	long. Put the decision in SQL (a WHERE clause, an upsert, INSERT ...
	SELECT) or accept that the read is a moment old.

	A value in a statement's list cannot be a bare nil (the list would lose
	its place); write Sqlite.null there.
]]
function Database.batch(self: Database, statements: { Statement }, options: BatchOptions?): ({ Outcome }?, string?)
	local prepared: { string } = {}
	for index, statement in statements do
		if type(statement) == "string" then
			prepared[index] = Bind.apply(statement, nil)
		else
			local sql = statement[1]
			if type(sql) ~= "string" then
				error(`sqlite: statement {index} of the batch has no SQL in first place`, 0)
			end
			prepared[index] = Bind.apply(sql, Bind.pack(table.unpack(statement, 2, #statement)))
		end
	end
	if #prepared == 0 then
		return {}, nil
	end
	local mode = (if options and options.mode then options.mode else "immediate"):upper()
	if mode ~= "IMMEDIATE" and mode ~= "DEFERRED" and mode ~= "EXCLUSIVE" then
		error(`sqlite: unknown batch mode "{mode:lower()}"`, 0)
	end
	return run(self, prepared, mode)
end

--[[
	Run SQL text as it stands: any number of statements, no values. For
	schema -- CREATE TABLE, CREATE TRIGGER (whose body has semicolons of its
	own, which is why the one-statement methods will not take it), PRAGMAs.

	Runs in a transaction unless told otherwise, so half a schema is never
	left behind. Pass `false` for the few statements SQLite will not run
	inside one (VACUUM, PRAGMA journal_mode).

	Never build this text out of anything a user typed. Values go through the
	other methods, which is where they are made safe.
]]
function Database.script(self: Database, text: string, transaction: boolean?): (boolean, string?)
	local commands = if transaction == false then { text } else { "BEGIN IMMEDIATE", text, "COMMIT" }
	local output, err = Cli.run(self.config, commands)
	if output == nil then
		return false, err
	end
	return true, nil
end

--[[
	Bring the schema up to date.

	`migrations` is the schema's whole history, oldest first, each entry SQL
	text as for `script`. The database remembers how many it has had (PRAGMA
	user_version); the rest are applied in order, each in its own transaction
	together with the new version number, so a migration that fails leaves
	the database exactly as the one before it did.

	Only ever add to the end of the list. Returns the version the database is
	now at. Run it from one place at startup: two processes migrating the
	same file at once would both try the same step, and the second would fail.
]]
function Database.migrate(self: Database, migrations: { string }): (number?, string?)
	local current, err = self:value("PRAGMA user_version")
	if err ~= nil then
		return nil, err
	end
	local version = (current :: number?) or 0
	for index = version + 1, #migrations do
		local output, failure = Cli.run(self.config, {
			"BEGIN IMMEDIATE",
			migrations[index],
			`PRAGMA user_version = {index}`,
			"COMMIT",
		})
		if output == nil then
			return nil, `migration {index}: {failure}`
		end
		version = index
	end
	return version, nil
end

return Database
