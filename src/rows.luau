--!strict
--[[
	Reading what the sqlite3 shell printed.

	The shell is run in "quote" mode, where every value is printed as the SQL
	literal that would produce it:

	    'name','rank','marks','crest'          the header, when there are rows
	    'Marta Vogel','Captain',1500,X'00ff'
	    'it''s',NULL,0.5,NULL

	That is the one output mode that is unambiguous. A string is always in
	quotes, so a comma or a line break inside one is plainly part of it; NULL
	is not the same as 'NULL' or ''; a blob is not a string. List, CSV and
	JSON modes each lose at least one of those.

	Two spellings of a string have to be understood, because the shell changed
	its mind: before 3.50 a control character is printed raw inside the
	quotes, from 3.50 on the string is wrapped as unistr('...') with the
	character written \u000a. Both read back to the same bytes here.
]]
local Rows = {}

export type Row = { [string]: any }

export type Result = {
	-- Column names in the order the statement gave them. Empty when the
	-- statement returned no rows: the shell prints no header for nothing.
	columns: { string },
	rows: { Row },
}

-- Whole numbers a double holds exactly. Larger ones are handed back as the
-- digits SQLite printed, because a wrong id is worse than a string.
local SAFE_INTEGER = 2 ^ 53

local NULL = table.freeze({})

local HEX_VALUE: { [number]: number } = {}
for digit = 0, 9 do
	HEX_VALUE[48 + digit] = digit
end
for letter = 0, 5 do
	HEX_VALUE[65 + letter] = 10 + letter
	HEX_VALUE[97 + letter] = 10 + letter
end

local function fromHex(digits: string): buffer
	local out = buffer.create(#digits // 2)
	for index = 0, #digits // 2 - 1 do
		local high = HEX_VALUE[string.byte(digits, index * 2 + 1)]
		local low = HEX_VALUE[string.byte(digits, index * 2 + 2)]
		if high == nil or low == nil then
			error("sqlite: unreadable blob in the shell's output", 0)
		end
		buffer.writeu8(out, index, high * 16 + low)
	end
	return out
end

-- The body of a quoted string that opens at `from`; returns it and the
-- position after the closing quote.
local function quoted(text: string, from: number): (string, number)
	local parts: { string } = {}
	local at = from + 1
	while true do
		local close = text:find("'", at, true)
		if close == nil then
			error("sqlite: the shell's output ended inside a string", 0)
		end
		table.insert(parts, text:sub(at, close - 1))
		if text:sub(close + 1, close + 1) == "'" then
			table.insert(parts, "'")
			at = close + 2
		else
			return table.concat(parts), close + 1
		end
	end
end

-- unistr()'s escapes: \\ for a backslash, and a code point as \XXXX, \uXXXX,
-- \+XXXXXX or \UXXXXXXXX.
local function unescape(text: string): string
	if text:find("\\", 1, true) == nil then
		return text
	end
	local parts: { string } = {}
	local at = 1
	while true do
		local slash = text:find("\\", at, true)
		if slash == nil then
			table.insert(parts, text:sub(at))
			break
		end
		table.insert(parts, text:sub(at, slash - 1))
		local mark = text:sub(slash + 1, slash + 1)
		local digits: string?
		if mark == "\\" then
			table.insert(parts, "\\")
			at = slash + 2
			continue
		elseif mark == "u" then
			digits = text:match("^%x%x%x%x", slash + 2)
			at = slash + 6
		elseif mark == "U" then
			digits = text:match("^%x%x%x%x%x%x%x%x", slash + 2)
			at = slash + 10
		elseif mark == "+" then
			digits = text:match("^%x%x%x%x%x%x", slash + 2)
			at = slash + 8
		else
			digits = text:match("^%x%x%x%x", slash + 1)
			at = slash + 5
		end
		if digits == nil then
			error("sqlite: unreadable escape in the shell's output", 0)
		end
		table.insert(parts, utf8.char(tonumber(digits, 16) :: number))
	end
	return table.concat(parts)
end

local function number(token: string): any
	if token:match("^%-?%d+$") then
		local value = tonumber(token) :: number
		return if math.abs(value) < SAFE_INTEGER then value else token
	elseif token == "Inf" then
		return math.huge
	elseif token == "-Inf" then
		return -math.huge
	end
	local value = tonumber(token)
	if value == nil then
		error(`sqlite: unreadable value in the shell's output: {token:sub(1, 40)}`, 0)
	end
	return value
end

-- One printed line of values, starting at `from`. Returns the values (NULL
-- as a marker, so the list keeps its length) and the position of the next
-- line.
local function record(text: string, from: number): ({ any }, number)
	local values: { any } = {}
	local at = from
	while true do
		local value: any
		local first = string.byte(text, at)
		if first == 39 then -- '
			value, at = quoted(text, at)
		elseif first == 117 and text:sub(at, at + 7) == "unistr('" then
			local body
			body, at = quoted(text, at + 7)
			value = unescape(body)
			at += 1 -- the closing parenthesis
		elseif (first == 88 or first == 120) and string.byte(text, at + 1) == 39 then -- X'
			local close = text:find("'", at + 2, true)
			if close == nil then
				error("sqlite: the shell's output ended inside a blob", 0)
			end
			value = fromHex(text:sub(at + 2, close - 1))
			at = close + 1
		else
			local stop = text:find("[,\n]", at) or (#text + 1)
			local token = text:sub(at, stop - 1)
			value = if token == "NULL" then NULL else number(token)
			at = stop
		end
		table.insert(values, value)
		local after = string.byte(text, at)
		if after == 44 then -- ,
			at += 1
		elseif after == 13 and string.byte(text, at + 1) == 10 then
			return values, at + 2
		else
			return values, at + 1 -- a line break, or the end
		end
	end
end

local function finish(records: { { any } }): Result
	local header = records[1]
	if header == nil then
		return { columns = {}, rows = {} }
	end
	local columns: { string } = {}
	for index, name in header do
		columns[index] = tostring(name)
	end
	local rows: { Row } = {}
	for index = 2, #records do
		local row: Row = {}
		for position, value in records[index] do
			if value ~= NULL then
				row[columns[position]] = value
			end
		end
		rows[index - 1] = row
	end
	return { columns = columns, rows = rows }
end

--[[
	Split the shell's output into one result per statement.

	`marker` is a line the caller had the shell print after each statement.
	It is only looked for at the start of a line and never inside a string,
	and no printed value can begin a line looking like it, so data cannot be
	mistaken for it.
]]
function Rows.parse(output: string, marker: string): { Result }
	local results: { Result } = {}
	local records: { { any } } = {}
	local at = 1
	local length = #output
	local markerLength = #marker
	while at <= length do
		if output:sub(at, at + markerLength - 1) == marker then
			local after = string.byte(output, at + markerLength)
			if after == nil or after == 10 or after == 13 then
				table.insert(results, finish(records))
				records = {}
				at = (output:find("\n", at + markerLength, true) or length) + 1
				continue
			end
		end
		local values
		values, at = record(output, at)
		table.insert(records, values)
	end
	if #records > 0 then
		table.insert(results, finish(records))
	end
	return results
end

return Rows
