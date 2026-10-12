# lute-sqlite

[SQLite](https://sqlite.org) for [Lute](https://lute.luau.org), the standalone Luau
runtime.

```luau
local Sqlite = require("@sqlite")

local db = assert(Sqlite.open("./data/panel.db"))

assert(db:migrate({
	[[CREATE TABLE notes (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, text TEXT NOT NULL, at INTEGER NOT NULL)]],
	[[CREATE INDEX notes_user ON notes (user_id, at)]],
}))

db:exec("INSERT INTO notes (user_id, text, at) VALUES (?, ?, ?)", 156, "Keep it in character", os.time())

for _, note in assert(db:query("SELECT text, at FROM notes WHERE user_id = ? ORDER BY at DESC", 156)) do
	print(note.at, note.text)
end
```

## How it works, and the catch

**Lute cannot load a SQLite library.** It has no SQLite module and no way to bind a C
library. This package therefore drives the official `sqlite3` command-line shell through
`process.run`: every call starts one short process that opens the file, runs what it was
given, prints the result and exits.

What makes that safe rather than merely expedient:

- **No shell is involved.** `process.run` takes an argument array. Each statement is one
  argument; no punctuation in it can become a command.
- **Values never travel as free text.** `sqlite3` has no way to take a statement and its
  values separately, so they are written into the SQL here, by one rule: a printable
  string is quoted with every `'` doubled (SQLite strings have no other escape); any
  string with a control character in it is sent as hex; a buffer is a hex blob; numbers
  are formatted, never passed through. A scanner that understands strings, quoted names
  and comments finds the placeholders, so the `?` in `'what?'` is left alone.
- **`sqlite3` runs with `-safe`**, which turns off what reaches outside the database:
  `.shell`, `.read`, `ATTACH`, `writefile()`, `load_extension()`. Only SQL is accepted in
  the first place (a statement starting with a dot is refused), so even SQL assembled
  carelessly cannot touch another file or start a program.

The test suite stores, searches for and reads back
``a;rm -rf /;b "quoted" 'single' $(whoami) `id` \ '); DROP TABLE players; --`` (with a
newline, a tab and a `.shell` line in it) byte for byte.

What it costs:

- **A process per call**, about 4 ms. Fine for an admin panel or a bot. Not for a hot
  loop; put many statements in one `batch` instead (3000 inserts: about 55 ms).
- **No connection outlives a call.** You cannot read a row, decide in Luau, then write,
  all inside one transaction. A transaction is a list of statements handed over together
  (`batch`). Put the decision in SQL (`WHERE`, an upsert, `INSERT ... SELECT`), or accept
  that the read is a moment old.

Calls do not block Lute's scheduler: other tasks keep running while one waits on the
database, including while it waits for another process's lock.

## Requirements

`sqlite3` 3.37 or later on `PATH` (or pass `path`). macOS ships it; on Debian or Ubuntu
it is `apt install sqlite3`. Shells before 3.50 print strings with control
characters differently; the parser reads both forms. The whole suite passes against 3.54
(macOS) and 3.45 (Ubuntu 24.04).

## API

Every method returns `(value, error)`. A failed constraint, a locked file or bad SQL is
an error value, not a raise. A mistake in the call itself (three values for two
placeholders, a table where a value should be) raises, because that is a bug.

```luau
local db, err = Sqlite.open(file, {
	path = "sqlite3",       -- the executable
	busyTimeoutMs = 5000,   -- how long to wait for another process's lock
	foreignKeys = true,     -- enforce FOREIGN KEY constraints
	wal = true,             -- write-ahead log: readers and the writer do not block each other
})
```

| Call | Returns |
| --- | --- |
| `db:query(sql, ...)` | every row, each `{ column = value }` |
| `db:first(sql, ...)` | the first row, or `nil` (with no error) when there is none |
| `db:value(sql, ...)` | the first column of the first row |
| `db:exec(sql, ...)` | `{ changes, lastInsertRowid }` |
| `db:batch(statements, { mode })` | one `{ rows, columns, changes, lastInsertRowid }` per statement; all in one transaction |
| `db:script(text, transaction)` | `true`; runs schema text of any number of statements, no values |
| `db:migrate(list)` | the schema version now; applies the entries the file has not had |
| `Sqlite.name(identifier)` | the identifier quoted for use as a table or column name |
| `Sqlite.null` | a NULL that can sit in a list |

### Values

```luau
db:query("SELECT * FROM t WHERE a = ? AND b = ?", 1, "x")       -- positional
db:query("SELECT * FROM t WHERE a = ?2 AND b = ?1", "x", 1)     -- numbered
db:query("SELECT * FROM t WHERE a = :a AND b = :b", { a = 1, b = "x" })  -- named (:a, @a or $a)
```

| Luau | SQLite | Back as |
| --- | --- | --- |
| `nil`, `Sqlite.null` | NULL | absent from the row |
| `boolean` | INTEGER 1 / 0 | `number` |
| whole `number` under 2^53 | INTEGER | `number` |
| other `number` | REAL | `number` |
| `string` | TEXT | `string` |
| `buffer` | BLOB | `buffer` |

- An INTEGER beyond 2^53 comes back as a **string** of its digits: a double cannot hold
  it exactly, and a wrong id is worse than a string.
- **Text cannot contain a NUL byte.** SQLite would store it, but `sqlite3` prints text as
  a C string and would hand back only the part before the NUL. Such a string is refused
  with an error; store it as a blob (`buffer.fromstring(value)`).
- **On `sqlite3` older than 3.50, text cannot contain a CR LF line break.** Lute turns every
  CR LF in a child process's output into LF, and a shell that old prints text as it is, so the
  string would come back changed. It is refused with an error; use LF line endings or a blob. A
  lone CR or LF is fine, and from 3.50 on the shell escapes control characters, so nothing is
  affected. (Text with CR LF that something else wrote to the file reads back with LF on an old
  shell: that cannot be seen from here.)
- NaN is refused (SQLite turns it into NULL).
- A NULL column is absent from its row, so `row.note == nil`. If two columns in a result
  share a name, the later one wins; give them aliases.

### One statement per call

`query`, `first`, `value`, `exec` and each entry of a `batch` take exactly one statement;
a second one after a `;` raises. That is what makes the rows and the change count belong
to something definite. Schema text with several statements, and `CREATE TRIGGER` (whose
body has semicolons of its own), go through `script` or `migrate`.

### Batches

```luau
local results, err = db:batch({
	{ "UPDATE purse SET marks = marks - ? WHERE user_id = ?", 250, 5 },
	{ "UPDATE purse SET marks = marks + ? WHERE user_id = ?", 250, 6 },
	{ "INSERT INTO ledger (from_id, to_id, note) VALUES (?, ?, ?)", 5, 6, Sqlite.null },
})
```

All of it happens or none of it does. Inside a statement's list a bare `nil` would lose
its place, so write `Sqlite.null`. `mode` is `"immediate"` (default; takes the write lock
first), `"deferred"` (for a batch that only reads) or `"exclusive"`.

A batch too large for a command line is sent through a temporary file beside the
database, which is removed afterwards. That path cannot use `-safe` (which forbids
reading a file), so a statement that large with a line starting with a dot is refused.

### Migrations

```luau
local version, err = db:migrate({
	"CREATE TABLE a (x INTEGER)",                       -- 1
	"ALTER TABLE a ADD COLUMN y TEXT",                  -- 2
})
```

The list is the schema's whole history; only ever add to the end. The file remembers how
many it has had (`PRAGMA user_version`). Each entry runs in its own transaction with its
version number, so a failed migration leaves nothing behind. Run it from one place at
startup.

## Using it from another project

Point an alias at `src`, directly or through a link:

```json
{ "aliases": { "sqlite": "../lute-sqlite/src" } }
```

## Tests

```
lute run tests/run.luau
```

`bind` and `rows` need nothing. `database` runs against a real `sqlite3` in
`tests/_scratch` and skips if there is none.
