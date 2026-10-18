# sndb

Documentation can be found at https://loopy5418.github.io/sndb-docs !

An embedded, typed database for [Sonata](https://sonata.5418.org/docs). Database → table → column → row.

```luau
local sndb = require("@sndb")

local db = sndb.open("app.sndb")
local users = db:table("users", {
	name = "string",
	email = { type = "email", unique = true },
	age = { type = "int", min = 0, index = true },
	role = { type = sndb.enum("user", "admin"), default = "user" },
	bio = "string?",
})

users:insert({ name = "Ada", email = "ada@x.io", age = 36 })
local admins = users:where("role", "admin"):orderBy("age", "desc"):get()
users:query():where("age", "<", 18):update({ role = "user" })
db:close()
```

Run the tests with `sn run --entry tests/run.luau` and the benchmark with `sn run --entry tests/bench.luau -- 100000`.

## Layout

| Folder     | Contents                                                     |
| ---------- | ------------------------------------------------------------ |
| `core/`    | `database`, `table` (rows, indexes, schema), shared `util`   |
| `query/`   | chainable `query`, filter operators, full-text `search`      |
| `types/`   | the type `registry`: built-ins and custom types              |
| `storage/` | `codec` (columnar binary), `binary` and `json` formats, `store` (files, compression, journal) |

## Storage

`sndb.open(path, options)` options:

| Option        | Values                                                        | Default |
| ------------- | ------------------------------------------------------------- | ------- |
| `format`      | `"binary"` (columnar, compact) or `"json"` (readable)         | `"binary"` |
| `compression` | `"zstd"`, `"gzip"`, `"zlib"`, `"deflate"`, `"none"`           | zstd for binary, none for json |
| `level`       | a number, `"fast"`, `"default"`, `"best"`                     | |
| `layout`      | `"file"` (one file) or `"dir"` (a file per table; only changed tables are rewritten) | detected |
| `password`    | encrypts the files and the journal                            | |
| `sync`        | `"journal"`: each change is appended to a journal, compacted on `save`/`close` or past `journalLimit` bytes. `"full"`: rewrite after every change. `"manual"`: only `save()`/`close()` write. | `"journal"` |
| `pretty`      | indent JSON                                                   | |

The binary format stores each column separately: integers as delta varints, floats as f32 when lossless, repeated strings dictionary-encoded, booleans and nulls as bitmaps, then compresses the result. Existing files are detected on open, so only `password` is needed to reopen one.

`sndb.memory()` makes a database that is never written; `db:backup(path, options)` writes a full copy of any database in any format.

## Types

Built in: `string`/`text`, `int`/`integer`, `float`/`number`, `bool`/`boolean`, `blob`, `any`/`json`, `datetime`, `uuid`, `email`, `enum(...)`, `array(of)`.

Columns: a type name (`"int"`, `"string?"` for optional), or a table with `type`, `optional`, `default` (value or function), `primary`, `unique`, `index`, `auto` (counter for ints, generated for `uuid`/`datetime`), `min`/`max` (number value or string/array length), `pattern`, `check(v) -> (ok, err?)`. Without a primary column, an auto-increment `id` is added.

Custom types extend a base type, optionally converting to and from it:

```luau
sndb.define("vec2", {
	base = "string",
	check = function(v) return type(v) == "table" and type(v.x) == "number", "expected {x, y}" end,
	serialize = function(v) return `{v.x},{v.y}` end,
	deserialize = function(s) local x, y = s:match("^(.-),(.*)$") return { x = tonumber(x), y = tonumber(y) } end,
	compare = function(a, b) return a.x < b.x end, -- optional ordering
})

sndb.define("money", function(currency) -- parameterised: { type = { "money", "EUR" } }
	return { base = "int", check = function(v) return v >= 0, `negative {currency}` end }
end)
```

Define custom types before opening a database that uses them.

## Queries

Every query method is available on tables directly and returns a new query (`users:where(...)`).

- **Filters:** `where(col, value)`, `where(col, op, value)`, `where({ col = value, ... })`, `where(function(row) ... end)`, `where(col, function(value) ... end)`, `where(otherQuery)` for grouping, plus `orWhere`, `whereNot`, `orWhereNot`, `whereIn`, `whereNotIn`, `whereBetween`, `whereNull`, `whereNotNull`.
- **Operators:** `=` `!=` `<` `<=` `>` `>=` `in` `not in` `between` `not between` `like` `ilike` `not like` (`%`, `_`) `contains` `icontains` (substrings or array items) `startsWith` `endsWith` `match` (Lua pattern) `regex` `iregex` `null` `not null`.
- **Search:** `search(text, { columns?, fuzzy?, mode = "all" | "any", weights? })` ranks rows by relevance across text columns.
- **Shaping:** `orderBy(col, "asc" | "desc")` or `orderBy(function(a, b) ... end)`, `limit`, `offset`, `page(n, size)`, `select(...)`.
- **Reading:** `get`/`all`, `first`, `count`, `exists`, `each`, `pluck`, `sum`, `avg`, `min`, `max`, `distinct`, `groupBy`, `countBy`, `paginate(page, size)`.
- **Mass editing:** `update(changes)` (function values receive `(old, row)`), `update(function(row) ... end)` (return changes or edit the row), `increment(col, n)`, `decrement(col, n)`, `delete()`. Use `table:query()` to target every row. Each call is atomic.

Equality and `in` filters on indexed columns use the index. Use `sndb.null` to set a value to null in an update.

## Tables and databases

- **Rows:** `insert`, `insertMany`, `get(pk)`, `has(pk)`, `update(pk, changes)`, `upsert(row, onColumn?)`, `delete(pk)`, `clear()`. Returned rows are copies.
- **Schema:** `addColumn`, `dropColumn`, `renameColumn`, `alterColumn(name, def, convert?)`, `createIndex(col, unique?)`, `dropIndex`, `columnList()`.
- **Database:** `db:table(name, columns?)` (creates, or adds new columns to an existing table), `createTable`, `dropTable`, `renameTable`, `hasTable`, `tables()`, `db.<name>`, `transaction(fn)` (nestable; rolls back everything, schema included, on error), `save`, `close`, `backup`, `stats`.
