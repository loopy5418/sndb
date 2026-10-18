local datetime = require("@sonata/datetime")
local fs = require("@sonata/fs")
local sndb = require("../init")

local N = tonumber(args[1]) or 100000
local tmp = fs.makeTempDir("sndb-bench-")

local function time(label: string, fn: () -> any): any
	local t0 = datetime.monotonic()
	local r = fn()
	print(string.format("%-34s %8.1f ms", label, (datetime.monotonic() - t0) * 1000))
	return r
end

local CITIES = { "Paris", "Tokyo", "Lima", "Oslo", "Cairo", "Denver", "Perth", "Seoul" }
local rows = table.create(N)
for i = 1, N do
	rows[i] = {
		name = `user{i}`,
		city = CITIES[i % #CITIES + 1],
		age = 18 + i % 60,
		score = (i % 1000) / 4,
		active = i % 3 ~= 0,
	}
end

local db = sndb.memory()
local users = db:table("users", {
	name = { type = "string", unique = true },
	city = { type = "string", index = true },
	age = "int",
	score = "float",
	active = "bool",
})

time(`insertMany {N} rows`, function()
	users:insertMany(rows)
end)
time("1000x get by primary key", function()
	for i = 1, 1000 do
		users:get(i * (N // 1000))
	end
end)
time("1000x indexed unique lookup", function()
	for i = 1, 1000 do
		users:where("name", `user{i}`):first()
	end
end)
time("indexed non-unique (city = Oslo)", function()
	return users:where("city", "Oslo"):count()
end)
time("full scan (age > 50, active)", function()
	return users:where("age", ">", 50):where("active", true):count()
end)
time("scan + sort + limit 10", function()
	return users:where("city", "Lima"):orderBy("score", "desc"):limit(10):get()
end)
time("search 'user123'", function()
	return users:search("user123"):count()
end)
time("mass update (city = Paris)", function()
	return users:query():where("city", "Paris"):increment("age")
end)
time("mass delete (age = 18)", function()
	return users:query():where("age", 18):delete()
end)

local function size(p: string): number
	if fs.isDir(p) then
		local s = 0
		for _, f in fs.listDir(p) do
			s += fs.stat(`{p}/{f}`).size
		end
		return s
	end
	return fs.stat(p).size
end

for _, o in
	{
		{ "binary + zstd", "a.sndb", {} },
		{ "binary + zstd best", "b.sndb", { level = "best" } },
		{ "binary + gzip", "c.sndb", { compression = "gzip" } },
		{ "binary uncompressed", "d.sndb", { compression = "none" } },
		{ "json", "e.json", { format = "json" } },
		{ "json + zstd", "f.sndb", { format = "json", compression = "zstd" } },
	} :: { any }
do
	local p = `{tmp}/{o[2]}`
	time(`save {o[1]}`, function()
		db:backup(p, o[3])
	end)
	local loaded = time(`  load ({math.floor(size(p) / 1024)} KiB)`, function()
		return sndb.open(p)
	end)
	assert(loaded.users:count() == users:count())
end

local jp = `{tmp}/journal.sndb`
local jdb = sndb.open(jp)
local jt = jdb:table("t", { v = "int" })
time("1000 single inserts (journal sync)", function()
	for i = 1, 1000 do
		jt:insert({ v = i })
	end
end)
local fdb = sndb.open(`{tmp}/full.sndb`, { sync = "full" })
local ft = fdb:table("t", { v = "int" })
time("1000 single inserts (full sync)", function()
	for i = 1, 1000 do
		ft:insert({ v = i })
	end
end)

fs.removeDir(tmp, true)
