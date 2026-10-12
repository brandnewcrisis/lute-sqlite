--!strict
--[[
	Transport: the sqlite3 shell, driven through process.run.

	Lute has no SQLite binding and no way to load one, so the database is
	reached the way lute-valkey reaches Valkey: by running the official
	command-line client. Every call is one short-lived process (about 4 ms)
	that opens the file, runs what it was given and exits.

	What makes that safe:

	  * process.run takes an ARGUMENT ARRAY and never a shell string. Each
	    statement is one argument; nothing in it can become a command.
	  * the shell is started with -safe, which turns off what reaches outside
	    the database (.shell, .read, ATTACH, readfile and the like), and
	    nothing but SQL is accepted here in the first place: a statement that
	    starts with a dot is refused before the shell sees it. So even SQL
	    that was put together carelessly cannot touch another file or run a
	    program.
	  * values never arrive here as text of their own; see @sqlite/bind.

	And what it costs:

	  * a process per call. Fine for a panel or a bot; not for a hot loop.
	    Use `batch` to do many things in one process.
	  * no connection outlives a call, so nothing can be read, decided on in
	    Luau, and written within one transaction. A transaction is a list of
	    statements handed over together.
]]
local crypto = require("@lute/crypto")
local fs = require("@lute/fs")
local process = require("@lute/process")
local Bind = require("@sqlite/bind")

local Cli = {}

export type Config = {
	-- The sqlite3 executable.
	path: string,
	-- The database file.
	file: string,
	-- How long a call waits for another process's lock before giving up.
	busyTimeoutMs: number,
	foreignKeys: boolean,
}

-- A line the shell is told to print after each statement, so the results
-- can be told apart. PRINT is the only dot-command this package ever sends.
Cli.MARKER = "--lute-sqlite--"
Cli.PRINT = ".print " .. Cli.MARKER

--[[
	Linux refuses a single argument over 128 KiB, and every system caps the
	whole command line. A statement carrying a large blob, or a batch of
	thousands, goes through a file the shell is told to read instead.
]]
local MAX_ARGUMENT = 100_000
local MAX_COMMAND_LINE = 400_000

-- The shell's own words for what went wrong, without its bookkeeping
-- ("Parse error in 4th command line argument: ", "Runtime error near line
-- 3: ") in front.
local PREFIXES = {
	"^Parse error [^:]*: ",
	"^Runtime error [^:]*: ",
	"^Error in [^:]*: ",
	"^Error: near line %d+: ",
	"^Error: in prepare, ",
	"^Error: ",
	"^line %d+: ",
	"^argv%[%d+%]: ",
}

local function reason(stderr: string, exitcode: number): string
	local line = stderr:match("^%s*([^\n]+)") or ""
	for _, prefix in PREFIXES do
		local stripped, count = line:gsub(prefix, "")
		if count > 0 then
			line = stripped
			break
		end
	end
	line = line:gsub("%s+$", "")
	return if line == "" then `sqlite3 exited with status {exitcode}` else line
end

local function spawn(argv: { string }): (string?, string?)
	-- A missing executable raises out of process.run instead of returning a
	-- failed result, so the spawn itself is guarded.
	local options: process.ProcessRunOptions = {}
	local ok, result = pcall(process.run, argv, options)
	if not ok then
		return nil, `could not run {argv[1]}: {result}`
	end
	local run = result :: process.ProcessResult
	if not run.ok then
		return nil, reason(run.stderr, run.exitcode)
	end
	return run.stdout, nil
end

local function directoryOf(path: string): string
	return path:match("^(.*)/[^/]*$") or "."
end

-- Sixteen hex digits nobody else will pick. math.random would not do: it
-- starts from the same seed in every process.
local function token(): string
	return Bind.hex(buffer.tostring(crypto.secretbox.keygen())):sub(1, 16):lower()
end

local function throughFile(config: Config, base: { string }, commands: { string }): (string?, string?)
	if config.file:find('["\\\n]') then
		return nil, "the database path contains a quote, a backslash or a line break, which this much SQL cannot be sent past"
	end
	local lines: { string } = {}
	for index, command in commands do
		table.insert(lines, command)
		if command ~= Cli.PRINT then
			--[[
				Read from a file, the shell takes a line that begins with a dot
				as one of its own commands, and -safe (which forbids .read)
				cannot be on to stop it. Nothing here writes such a line, so one
				would have to come from the SQL text; refuse it.
			]]
			if command:find("\n%.") then
				return nil, `statement {index} is too large to send as an argument and has a line starting with a dot, which cannot go through a file; indent that line`
			end
			-- On its own line, so a statement ending in a `--` comment is
			-- still ended.
			table.insert(lines, ";")
		end
	end
	-- Beside the database: the same people can read it as can read the data.
	local path = `{directoryOf(config.file)}/.lute-sqlite-{token()}.sql`
	local wrote, problem = pcall(function()
		local handle = fs.open(path, "w")
		fs.write(handle, table.concat(lines, "\n") .. "\n")
		fs.close(handle)
	end)
	if not wrote then
		return nil, `could not write {path}: {problem}`
	end
	local argv = table.clone(base)
	table.insert(argv, `.read "{path}"`)
	local out, err = spawn(argv)
	pcall(fs.remove, path)
	return out, err
end

--[[
	Run commands against the database, in order, in one process.

	A command is a statement or a shell dot-command (`.print`). The first
	failure stops the run; a transaction left open by it is rolled back as
	the process exits. Returns everything the shell printed.
]]
function Cli.run(config: Config, commands: { string }): (string?, string?)
	local total = 0
	local oversized = false
	for index, command in commands do
		--[[
			A NUL byte cannot travel in an argument: argv is an array of
			NUL-terminated C strings. Values are safe (a string holding one is
			sent as hex), so this can only be the SQL text itself.
		]]
		if command:find("%z") then
			return nil, `statement {index} contains a NUL byte`
		end
		-- An argument that starts with a dot is a shell command, not SQL.
		if command ~= Cli.PRINT and command:match("^%s*%.") then
			return nil, `statement {index} starts with a dot; only SQL can be run`
		end
		total += #command
		oversized = oversized or #command > MAX_ARGUMENT
	end

	-- -init /dev/null: never a ~/.sqliterc. -batch: never a prompt.
	-- -bail: stop at the first error. -quote -header: see @sqlite/rows.
	local argv = { config.path, "-init", "/dev/null", "-batch", "-bail", "-quote", "-header" }
	local viaFile = oversized or total > MAX_COMMAND_LINE
	if not viaFile then
		table.insert(argv, "-safe") -- (.read is one of the things it forbids)
	end
	table.insert(argv, config.file)
	table.insert(argv, `.timeout {math.floor(config.busyTimeoutMs)}`)
	-- Per connection in SQLite, so it has to be said every time.
	table.insert(argv, `PRAGMA foreign_keys = {if config.foreignKeys then "ON" else "OFF"}`)

	if viaFile then
		return throughFile(config, argv, commands)
	end
	for _, command in commands do
		table.insert(argv, command)
	end
	return spawn(argv)
end

-- The shell's version as { major, minor, patch }, or nil and why not.
function Cli.version(path: string): ({ number }?, string?)
	local out, err = spawn({ path, "-version" })
	if out == nil then
		return nil, err
	end
	local major, minor, patch = out:match("^(%d+)%.(%d+)%.(%d+)")
	if major == nil then
		return nil, `{path} did not answer like sqlite3: {out:sub(1, 60)}`
	end
	return { tonumber(major) :: number, tonumber(minor) :: number, tonumber(patch) :: number }, nil
end

return Cli
