local fs = require("@sonata/fs")
local sndb = require("../init")

local passed, failed = 0, 0

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print(`FAIL {name}: {err}`)
	end
end

local function eq(a: any, b: any, msg: string?)
	if a ~= b then
		error(`{msg or "values differ"}: expected {tostring(b)}, got {tostring(a)}`, 2)
	end
end

local function raises(fn: () -> (), pattern: string?)
	local ok, err = pcall(fn)
	if ok then
		error("expected an error", 2)
	elseif pattern and not string.find(tostring(err), pattern) then
		error(`error '{err}' doesn't match '{pattern}'`, 2)
	end
end

local tmp = fs.makeTempDir("sndb-test-")

sndb.define("vec2", {
	base = "string",
	check = function(v)
		return type(v) == "table" and type(v.x) == "number" and type(v.y) == "number", "expected {x, y}"
	end,
	serialize = function(v)
		return `{v.x},{v.y}`
	end,
	deserialize = function(s)
		local x, y = string.match(s, "^(.-),(.*)$")
		return { x = tonumber(x), y = tonumber(y) }
	end,
	compare = function(a, b)
		return a.x * a.x + a.y * a.y < b.x * b.x + b.y * b.y
	end,
})

sndb.define("slug", {
	base = "string",
	check = function(v)
		return string.match(v, "^[a-z0-9%-]+$") ~= nil, "expected a slug"
	end,
})

local function schema(db)
	return db:table("users", {
		name = "string",
		email = { type = "email", unique = true },
		age = { type = "int", min = 0, max = 150, index = true },
		role = { type = sndb.enum("user", "mod", "admin"), default = "user" },
		tags = { type = sndb.array("string"), default = {} },
		bio = "string?",
		pos = "vec2?",
		handle = "slug?",
		active = { type = "bool", default = true },
		created = { type = "datetime", auto = true },
	})
end

local function seed(users)
	users:insertMany({
		{ name = "Alice Smith", email = "alice@x.io", age = 31, role = "admin", tags = { "ops", "lua" }, bio = "Loves databases" },
		{ name = "Bob Jones", email = "bob@x.io", age = 17, tags = { "games" }, pos = { x = 1, y = 2 } },
		{ name = "Carol White", email = "carol@x.io", age = 45, role = "mod", bio = "Writes Luau code" },
		{ name = "Dave Brown", email = "dave@x.io", age = 31, active = false, handle = "dave-b" },
		{ name = "Eve Black", email = "eve@x.io", age = 22, tags = { "lua", "security" } },
	})
end

test("insert, defaults and auto ids", function()
	local db = sndb.memory()
	local users = schema(db)
	local a = users:insert({ name = "A", email = "a@a.io", age = 1 })
	eq(a.id, 1)
	eq(a.role, "user")
	eq(a.active, true)
	eq(type(a.created), "number")
	eq(#a.tags, 0)
	eq(users:insert({ name = "B", email = "b@a.io", age = 2 }).id, 2)
	eq(users:count(), 2)
end)

test("validation", function()
	local users = schema(sndb.memory())
	raises(function()
		users:insert({ name = "x", email = "nope", age = 1 })
	end, "email")
	raises(function()
		users:insert({ name = "x", email = "x@x.io", age = -1 })
	end, "minimum")
	raises(function()
		users:insert({ name = "x", email = "x@x.io", age = 1.5 })
	end, "expected int")
	raises(function()
		users:insert({ email = "x@x.io", age = 1 })
	end, "required")
	raises(function()
		users:insert({ name = "x", email = "x@x.io", age = 1, role = "god" })
	end, "one of")
	raises(function()
		users:insert({ name = "x", email = "x@x.io", age = 1, nope = 1 })
	end, "unknown column")
	raises(function()
		users:insert({ name = "x", email = "x@x.io", age = 1, tags = { 1 } })
	end, "item 1")
	users:insert({ name = "x", email = "x@x.io", age = 1 })
	raises(function()
		users:insert({ name = "y", email = "x@x.io", age = 1 })
	end, "duplicate")
	eq(users:count(), 1)
end)

test("filters", function()
	local users = schema(sndb.memory())
	seed(users)
	eq(users:where("age", 31):count(), 2)
	eq(users:where("age", ">", 30):count(), 3)
	eq(users:where("age", ">=", 22):where("age", "<", 40):count(), 3)
	eq(users:where("age", "!=", 31):count(), 3)
	eq(users:whereIn("role", { "admin", "mod" }):count(), 2)
	eq(users:whereNotIn("role", { "admin", "mod" }):count(), 3)
	eq(users:whereBetween("age", 20, 31):count(), 3)
	eq(users:whereNull("bio"):count(), 3)
	eq(users:whereNotNull("bio"):count(), 2)
	eq(users:where("name", "like", "%o%"):count(), 3)
	eq(users:where("name", "ilike", "a%"):count(), 1)
	eq(users:where("name", "not like", "%o%"):count(), 2)
	eq(users:where("name", "startsWith", "Bob"):count(), 1)
	eq(users:where("name", "endsWith", "Black"):count(), 1)
	eq(users:where("bio", "icontains", "LUAU"):count(), 1)
	eq(users:where("tags", "contains", "lua"):count(), 2)
	eq(users:where("email", "match", "^[ab]"):count(), 2)
	eq(users:where("name", "regex", "^(alice|eve)", nil):count(), 0)
	eq(users:where("name", "iregex", "^(alice|eve)"):count(), 2)
	eq(users:where({ role = "user", active = true }):count(), 2)
	eq(users:where(function(r)
		return #r.tags >= 2
	end):count(), 2)
	eq(users:where("age", function(v)
		return v % 2 == 0
	end):count(), 1)
	eq(users:where("role", "admin"):orWhere("age", "<", 18):count(), 2)
	eq(users:whereNot("role", "user"):count(), 2)
	local adultsOrMods = users:where("age", ">=", 18):where(users:where("role", "mod"):orWhere("active", false))
	eq(adultsOrMods:count(), 2)
	eq(users:where("pos", { x = 1, y = 2 }):count(), 1)
	raises(function()
		users:where("age", "~~", 1)
	end, "unknown operator")
end)

test("ordering, paging, projection, aggregates", function()
	local users = schema(sndb.memory())
	seed(users)
	local rows = users:orderBy("age", "desc"):orderBy("name"):get()
	eq(rows[1].name, "Carol White")
	eq(rows[2].name, "Alice Smith")
	eq(rows[3].name, "Dave Brown")
	eq(users:orderBy("role"):first().role, "user")
	eq(users:orderBy("bio"):get()[5].bio, nil)
	local page = users:orderBy("id"):paginate(2, 2)
	eq(page.total, 5)
	eq(page.pages, 3)
	eq(page.items[1].id, 3)
	local p = users:select("name"):first() :: any
	eq(p.name, "Alice Smith")
	eq(p.age, nil)
	eq(users:sum("age"), 146)
	eq(users:avg("age"), 146 / 5)
	eq(users:min("age"), 17)
	eq(users:max("role"), "admin")
	eq(#users:distinct("age"), 4)
	eq(users:countBy("role").user, 3)
	eq(#users:groupBy("age")[31], 2)
	eq(table.concat(users:where("age", 31):pluck("name"), ","), "Alice Smith,Dave Brown")
	eq(users:where("age", 99):exists(), false)
	eq(users:offset(3):count(), 2)
	eq(users:limit(2):count(), 2)
end)

test("search", function()
	local users = schema(sndb.memory())
	seed(users)
	local hits = users:search("lua"):get()
	eq(#hits, 3)
	eq(users:search("alice smith"):first().name, "Alice Smith")
	eq(users:search("alice bob"):count(), 0)
	eq(users:search("alice bob", { mode = "any" }):count(), 2)
	eq(users:search("databse", { fuzzy = true }):count(), 1)
	eq(users:search("smith", { columns = { "email" } }):count(), 0)
	eq(users:search("lua"):where("age", "<", 30):count(), 1)
end)

test("mass editing", function()
	local users = schema(sndb.memory())
	seed(users)
	eq(users:query():where("age", "<", 18):update({ active = false }), 1)
	eq(users:where("active", false):count(), 2)
	users:query():update({
		age = function(v)
			return v + 1
		end,
	})
	eq(users:sum("age"), 151)
	users:where("role", "mod"):increment("age", 10)
	eq((users:get(3) :: any).age, 56)
	users:query():where("name", "like", "D%"):update(function(r)
		r.bio = "edited"
		r.tags = { "x" }
	end)
	eq((users:get(4) :: any).bio, "edited")
	users:query():where("id", 4):update({ bio = sndb.null })
	eq((users:get(4) :: any).bio, nil)
	raises(function()
		users:query():update({ email = "same@x.io" })
	end, "duplicate")
	eq((users:get(1) :: any).email, "alice@x.io", "failed mass update rolled back")
	eq(users:query():where("active", false):delete(), 2)
	eq(users:count(), 3)
	eq(users:where("age", 32):count(), 1, "index updated after edits")
	eq(users:clear(), 3)
	eq(users:count(), 0)
end)

test("single-row api", function()
	local users = schema(sndb.memory())
	seed(users)
	eq((users:get(2) :: any).name, "Bob Jones")
	eq(users:has(99), false)
	users:update(2, { age = 18 })
	eq((users:get(2) :: any).age, 18)
	raises(function()
		users:update(99, { age = 1 })
	end, "no row")
	users:upsert({ id = 2, name = "Bobby" })
	eq((users:get(2) :: any).name, "Bobby")
	local r = users:upsert({ name = "Zed", email = "zed@x.io", age = 50 })
	eq(r.id, 6)
	users:upsert({ email = "zed@x.io", age = 51 }, "email")
	eq((users:get(6) :: any).age, 51)
	eq(users:delete(6), true)
	eq(users:delete(6), false)
	local copy = users:get(1) :: any
	copy.tags[1] = "mutated"
	eq((users:get(1) :: any).tags[1], "ops", "returned rows are copies")
end)

test("transactions", function()
	local db = sndb.memory()
	local users = schema(db)
	seed(users)
	raises(function()
		db:transaction(function()
			users:insert({ name = "T", email = "t@x.io", age = 5 })
			users:query():where("age", ">", 30):delete()
			users:update(2, { name = "changed" })
			error("boom")
		end)
	end, "boom")
	eq(users:count(), 5)
	eq(users:get(2).name, "Bob Jones")
	eq(users:orderBy("id"):pluck("id")[3], 3, "order restored")
	eq(users:where("age", 31):count(), 2, "indexes restored")
	local ok = pcall(function()
		db:transaction(function()
			users:addColumn("score", { type = "float", default = 1.5 })
			users:renameColumn("bio", "about")
			users:dropColumn("handle")
			error("nope")
		end)
	end)
	eq(ok, false)
	eq(users.byName.score, nil)
	eq(users:whereNotNull("bio"):count(), 2)
	eq(users:whereNotNull("handle"):count(), 1)
	db:transaction(function()
		users:insert({ name = "Kept", email = "kept@x.io", age = 9 })
		pcall(function()
			db:transaction(function()
				users:insert({ name = "Lost", email = "lost@x.io", age = 9 })
				error("inner")
			end)
		end)
	end)
	eq(users:where("age", 9):count(), 1, "nested transaction acts as savepoint")
end)

test("schema changes", function()
	local db = sndb.memory()
	local users = schema(db)
	seed(users)
	users:addColumn("score", { type = "float", default = 0 })
	eq((users:get(1) :: any).score, 0)
	raises(function()
		users:addColumn("required", "int")
	end, "required")
	users:renameColumn("bio", "about")
	eq(users:whereNotNull("about"):count(), 2)
	users:alterColumn("age", "string", function(v)
		return tostring(v)
	end)
	eq((users:get(1) :: any).age, "31")
	users:createIndex("name", true)
	eq(users:where("name", "Bob Jones"):count(), 1)
	raises(function()
		users:insert({ name = "Bob Jones", email = "b2@x.io", age = "1" })
	end, "duplicate")
	users:dropIndex("name")
	users:dropColumn("score")
	eq(users.byName.score, nil)
	db:renameTable("users", "people")
	eq(db:hasTable("people"), true)
	eq(db.people:count(), 5)
	db:dropTable("people")
	eq(#db:tables(), 0)
end)

local function roundtrip(name: string, opts: any)
	test("storage: " .. name, function()
		local path = `{tmp}/{name}`
		local db = sndb.open(path, opts)
		local users = schema(db)
		seed(users)
		users:update(2, { age = 19 })
		users:delete(5)
		db:table("blobs", { data = "blob", meta = "json?" }):insert({ data = "\0\1\2\255", meta = { a = { 1, 2 }, b = true } })
		db:close()

		local db2 = sndb.open(path, { password = opts.password })
		local u2 = schema(db2)
		eq(u2:count(), 4)
		eq((u2:get(2) :: any).age, 19)
		eq((u2:get(2) :: any).pos.y, 2)
		eq((u2:get(1) :: any).tags[2], "lua")
		eq(u2:where("email", "dave@x.io"):first().handle, "dave-b")
		eq(u2:insert({ name = "New", email = "new@x.io", age = 1 }).id, 6, "auto counter persisted")
		local b = db2.blobs:first() :: any
		eq(b.data, "\0\1\2\255")
		eq(b.meta.a[2], 2)
		db2:close()
	end)
end

roundtrip("binary-zstd.sndb", {})
roundtrip("binary-gzip.sndb", { compression = "gzip", level = "best" })
roundtrip("binary-raw.sndb", { compression = "none" })
roundtrip("encrypted.sndb", { password = "hunter2" })
roundtrip("plain.json", { format = "json", pretty = true })
roundtrip("dir-db", { layout = "dir" })
roundtrip("dir-json", { layout = "dir", format = "json" })
roundtrip("full-sync.sndb", { sync = "full" })
roundtrip("manual.sndb", { sync = "manual" })

test("journal survives a crash", function()
	local path = `{tmp}/crash.sndb`
	local db = sndb.open(path)
	local users = schema(db)
	seed(users)
	users:update(1, { age = 99 })
	users:delete(2)
	users:query():where("role", "user"):update({ bio = "j" })
	eq(fs.isFile(path .. ".journal"), true)
	local db2 = sndb.open(path)
	local u2 = schema(db2)
	eq(u2:count(), 4)
	eq((u2:get(1) :: any).age, 99)
	eq(u2:where("bio", "j"):count(), 2)
	eq(fs.isFile(path .. ".journal"), false, "journal compacted on open")
	raises(function()
		sndb.open(`{tmp}/encrypted.sndb`)
	end, "password")
end)

test("backup converts formats", function()
	local db = sndb.memory()
	seed(schema(db))
	db:backup(`{tmp}/backup.json`, { format = "json" })
	local db2 = sndb.open(`{tmp}/backup.json`)
	eq(schema(db2):count(), 5)
	eq(db2:stats().format, "json")
end)

fs.removeDir(tmp, true)
print(`{passed} passed, {failed} failed`)
if failed > 0 then
	error("tests failed", 0)
end
