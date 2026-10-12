--!strict
--[[
	Putting values into a statement.

	The sqlite3 shell has no way to hand it a statement and its values
	separately, so the values have to become part of the SQL text. That is the
	one place an injection could happen, and this module is built so that it
	cannot:

	  * a string with nothing but printable characters becomes a quoted
	    literal with every `'` doubled. SQLite's string literals have no other
	    escape -- no backslashes, nothing a value could use to close the quote
	    early -- so this is the complete rule, the same one sqlite3_mprintf's
	    %Q applies;
	  * any other string (a newline, a tab, any control byte) never appears
	    as text at all: it is written as CAST(X'<hex>' AS TEXT), and hex
	    digits cannot be anything but hex digits;
	  * a buffer is a blob, X'<hex>';
	  * numbers are formatted here, never passed through as text.

	Placeholders are found by a scanner that knows what a string, a quoted
	name and a comment look like, so a `?` inside 'what?' stays a question
	mark.
]]
local Bind = {}

export type Value = boolean | number | string | buffer | nil

-- Positional values carry their count, because a nil in the middle (or at
-- the end) is a NULL and `#` would not see it.
export type Params = {
	count: number,
	values: { [number]: any },
	named: { [string]: any }?,
}

local HEX: { string } = {}
for byte = 0, 255 do
	HEX[byte + 1] = string.format("%02X", byte)
end

local function hex(bytes: string): string
	local parts: { string } = {}
	for index = 1, #bytes do
		parts[index] = HEX[string.byte(bytes, index) + 1]
	end
	return table.concat(parts)
end

Bind.hex = hex

-- A NULL that can be written where a bare nil cannot survive: in the middle
-- of a list of values.
Bind.null = table.freeze({})

-- Exactly representable whole numbers; beyond this a double has gaps.
local SAFE_INTEGER = 2 ^ 53

--[[
	One value as SQL text. Raises on what SQLite cannot hold, because that is
	a bug in the caller and not something to discover as a wrong row later.
]]
function Bind.literal(value: any, rawOutput: boolean?): string
	if value == nil or value == Bind.null then
		return "NULL"
	end
	local kind = type(value)
	if kind == "boolean" then
		return if value then "1" else "0"
	elseif kind == "number" then
		if value ~= value then
			error("sqlite: NaN cannot be stored (SQLite turns it into NULL); pass nil if that is what you mean", 0)
		elseif value == math.huge then
			return "9e999"
		elseif value == -math.huge then
			return "-9e999"
		elseif value == math.floor(value) and math.abs(value) < SAFE_INTEGER then
			return string.format("%d", value)
		end
		-- 17 significant digits is what it takes for a double to come back
		-- as the same double.
		return string.format("%.17g", value)
	elseif kind == "string" then
		--[[
			SQLite will store text with a NUL byte in it, but the shell prints
			text as a C string and stops at the NUL, so it could never be read
			back whole. Storing something that silently comes back shorter is
			worse than refusing it.
		]]
		if value:find("%z") then
			error("sqlite: a string containing a NUL byte cannot be read back as text; store it as a blob (buffer.fromstring(value))", 0)
		end
		--[[
			Lute hands back a child process's output with every CR LF turned
			into LF. A shell from 3.50 on prints control characters escaped,
			so that never touches a value; an older one prints them as they
			are, and text holding a CR LF would come back holding only the LF.
			Same rule as for NUL: refuse what could not be read back whole.
		]]
		if rawOutput and value:find("\r\n", 1, true) then
			error("sqlite: this sqlite3 (older than 3.50) could not hand a string containing a CR LF line break back intact; use LF line endings, or store it as a blob (buffer.fromstring(value))", 0)
		end
		if value:find("[\1-\31\127]") == nil then
			return "'" .. value:gsub("'", "''") .. "'"
		end
		return "CAST(X'" .. hex(value) .. "' AS TEXT)"
	elseif kind == "buffer" then
		return "X'" .. hex(buffer.tostring(value)) .. "'"
	end
	error(`sqlite: a {kind} cannot be stored; encode it first (JSON for a table)`, 0)
end

-- Past a quoted run that opened at `from`; a doubled quote is the escape.
local function afterQuoted(sql: string, from: number, quote: string): number
	local at = from + 1
	while true do
		local close = sql:find(quote, at, true)
		if close == nil then
			return #sql + 1 -- unterminated: SQLite will say so better than we can
		end
		if sql:sub(close + 1, close + 1) == quote then
			at = close + 2
		else
			return close + 1
		end
	end
end

-- Is there anything but blank space and comments from `from` on?
local function onlyTrailing(sql: string, from: number): boolean
	local at = from
	while at <= #sql do
		local two = sql:sub(at, at + 1)
		if two == "--" then
			at = (sql:find("\n", at, true) or #sql) + 1
		elseif two == "/*" then
			local close = sql:find("*/", at + 2, true)
			at = if close then close + 2 else #sql + 1
		elseif sql:sub(at, at):match("[%s;]") then
			at += 1
		else
			return false
		end
	end
	return true
end

--[[
	Fill a statement's placeholders.

	  * `?` takes the next positional value, `?3` the third;
	  * `:name`, `@name` and `$name` take `params.name`.

	A statement uses one style or the other. Every positional value must be
	used and every placeholder must have one; every named value must be used.
	(A named value that is absent is NULL: a table cannot hold a nil, so
	"not given" and "given as nil" are the same thing to it.)

	Also refuses a second statement after a `;`. One call runs one statement,
	which is what makes its rows and its change count unambiguous; use `batch`
	for several and `script` for schema text.
]]
function Bind.apply(sql: string, params: Params?, rawOutput: boolean?): string
	local named = if params then params.named else nil
	local values = if params then params.values else {}
	local count = if params then params.count else 0
	local used: { [any]: boolean } = {}
	local out: { string } = {}
	local copied = 1 -- everything before this is already in `out`
	local at = 1
	local nextIndex = 1
	local length = #sql

	local function emit(upTo: number, replacement: string, resume: number)
		table.insert(out, sql:sub(copied, upTo))
		table.insert(out, replacement)
		copied = resume
	end

	while at <= length do
		local found = sql:find("['\"`%[%-/%?:@$;]", at)
		if found == nil then
			break
		end
		local char = sql:sub(found, found)
		if char == "'" or char == '"' or char == "`" then
			at = afterQuoted(sql, found, char)
		elseif char == "[" then
			at = (sql:find("]", found + 1, true) or length) + 1
		elseif char == "-" then
			if sql:sub(found + 1, found + 1) == "-" then
				at = (sql:find("\n", found, true) or length) + 1
			else
				at = found + 1
			end
		elseif char == "/" then
			if sql:sub(found + 1, found + 1) == "*" then
				local close = sql:find("*/", found + 2, true)
				at = if close then close + 2 else length + 1
			else
				at = found + 1
			end
		elseif char == ";" then
			if not onlyTrailing(sql, found) then
				error("sqlite: one statement per call -- use db:batch for several, or db:script for schema text", 0)
			end
			at = found + 1
		elseif char == "?" then
			if named then
				error("sqlite: the statement uses ? but was given named values", 0)
			end
			local digits = sql:match("^%d+", found + 1)
			local index = if digits then tonumber(digits) :: number else nextIndex
			if index < 1 or index > count then
				error(`sqlite: the statement needs value {index} but {count} {if count == 1 then "was" else "were"} given`, 0)
			end
			nextIndex = math.max(nextIndex, index + 1)
			used[index] = true
			at = found + 1 + (if digits then #digits else 0)
			emit(found - 1, Bind.literal(values[index], rawOutput), at)
		else
			local name = sql:match("^[%a_][%w_]*", found + 1)
			if name == nil then
				at = found + 1
			else
				if not named then
					error(`sqlite: the statement uses {char}{name} but was not given named values`, 0)
				end
				used[name] = true
				at = found + 1 + #name
				emit(found - 1, Bind.literal(named[name], rawOutput), at)
			end
		end
	end
	table.insert(out, sql:sub(copied))

	if named then
		for name in named do
			if not used[name] then
				error(`sqlite: a value named "{name}" was given but the statement has no :{name}`, 0)
			end
		end
	else
		for index = 1, count do
			if not used[index] then
				error(`sqlite: {count} value{if count == 1 then " was" else "s were"} given but the statement has no placeholder for value {index}`, 0)
			end
		end
	end
	return table.concat(out)
end

--[[
	Turn what a method was called with into Params.

	    db:query(sql, 156, "x")             positional
	    db:query(sql, { 156, "x" })         positional, as one list
	    db:query(sql, { id = 156 })         named

	A lone buffer is a value, not a list of them.
]]
function Bind.pack(...: any): Params?
	local count = select("#", ...)
	if count == 0 then
		return nil
	end
	local first = (...)
	if count == 1 and type(first) == "table" and first ~= Bind.null then
		if #first > 0 or next(first) == nil then
			return { count = #first, values = first }
		end
		return { count = 0, values = {}, named = first }
	end
	local values: { [number]: any } = {}
	for index = 1, count do
		values[index] = (select(index, ...))
	end
	return { count = count, values = values }
end

return Bind
