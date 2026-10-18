local compress = require("@sonata/compress")
local fs = require("@sonata/fs")
local binary = require("./binary")
local codec = require("./codec")
local jsonfmt = require("./json")
local util = require("../core/util")

local fail = util.fail

local CODES = { none = 0, gzip = 1, zlib = 2, deflate = 3, zstd = 4 }
local NAMES = { [0] = "none", "gzip", "zlib", "deflate", "zstd" }
local MAX = 2 ^ 30

export type Options = {
	format: ("binary" | "json")?,
	layout: ("file" | "dir")?,
	compression: ("zstd" | "gzip" | "zlib" | "deflate" | "none")?,
	level: (number | "fast" | "default" | "best")?,
	password: string?,
	pretty: boolean?,
}

local Store = {}
Store.__index = Store

function Store.new(path: string, opts: Options)
	if opts.format and opts.format ~= "binary" and opts.format ~= "json" then
		fail("unknown format '%s'", tostring(opts.format))
	end
	if opts.compression and not CODES[opts.compression] then
		fail("unknown compression '%s'", tostring(opts.compression))
	end
	local layout = opts.layout or (if fs.isDir(path) then "dir" else "file")
	return setmetatable({
		path = path,
		layout = layout,
		format = opts.format,
		compression = opts.compression,
		level = opts.level,
		password = opts.password,
		pretty = opts.pretty,
		journal = if layout == "dir" then path .. "/journal" else path .. ".journal",
	}, Store)
end

function Store:settings(): (string, string)
	local format = self.format or "binary"
	local comp = self.compression
	if not comp then
		comp = if format == "json" then "none" elseif table.find(compress.formats(), "zstd") then "zstd" else "gzip"
	end
	return format, comp
end

function Store:pack(snaps: { binary.Snapshot }): string
	local format, comp = self:settings()
	local body = if format == "json" then jsonfmt.encode(snaps, self.pretty) else binary.encode(snaps)
	if format == "json" and comp == "none" and not self.password then
		return body
	end
	if comp ~= "none" then
		body = compress.compress(body, comp :: any, self.level, self.password)
	elseif self.password then
		comp = "zlib"
		body = compress.compress(body, "zlib", 0, self.password)
	end
	return "SNDB" .. string.char(1, if format == "json" then 1 else 0, CODES[comp]) .. body
end

function Store:unpack(data: string): { binary.Snapshot }
	if string.sub(data, 1, 4) ~= "SNDB" then
		self.format = self.format or "json"
		return jsonfmt.decode(data)
	end
	local _, fmt, code = string.byte(data, 5, 7)
	local format = if fmt == 1 then "json" else "binary"
	local body = string.sub(data, 8)
	self.format = self.format or format
	self.compression = self.compression or NAMES[code]
	if code ~= 0 then
		if compress.isEncrypted(body) and not self.password then
			fail("%s is encrypted; open it with a password", self.path)
		end
		local ok, out = pcall(compress.decompress, body, NAMES[code] :: any, MAX, self.password)
		if not ok then
			fail("can't read %s: %s", self.path, tostring(out))
		end
		body = out
	end
	return if format == "json" then jsonfmt.decode(body) else binary.decode(body)
end

function Store:fileFor(name: string): string
	local format, comp = self:settings()
	local plain = format == "json" and comp == "none" and not self.password
	return `{self.path}/{name}{if plain then ".json" else ".sndb"}`
end

local function isData(f: string): boolean
	return string.match(f, "%.sndb$") ~= nil or string.match(f, "%.json$") ~= nil
end

local function write(path: string, data: string)
	local tmp = path .. ".tmp"
	fs.writeFile(tmp, data)
	fs.move(tmp, path)
end

function Store:load(): ({ binary.Snapshot }, { any })
	local snaps = {}
	if self.layout == "dir" then
		if fs.isDir(self.path) then
			for _, f in fs.listDir(self.path) do
				if isData(f) then
					for _, s in self:unpack(fs.readFile(`{self.path}/{f}`)) do
						table.insert(snaps, s)
					end
				end
			end
		end
	elseif fs.isFile(self.path) then
		snaps = self:unpack(fs.readFile(self.path))
	end
	return snaps, self:readJournal()
end

-- "tables" maps names to objects with "dirty" and "_dump()"; "dir" only rewrites what changed.
function Store:save(tables: { [string]: any }, force: boolean?)
	if self.layout == "dir" then
		fs.makeDir(self.path, true)
		local keep = {}
		for name, t in tables do
			local p = self:fileFor(name)
			keep[p] = true
			if force or t.dirty or not fs.isFile(p) then
				write(p, self:pack({ t:_dump() }))
			end
		end
		for _, f in fs.listDir(self.path) do
			local p = `{self.path}/{f}`
			if isData(f) and not keep[p] then
				fs.removeFile(p)
			end
		end
	else
		local snaps = {}
		for _, t in tables do
			table.insert(snaps, t:_dump())
		end
		write(self.path, self:pack(snaps))
	end
	if fs.exists(self.journal) then
		fs.removeFile(self.journal)
	end
end

function Store:append(records: { any }): number
	local chunk = codec.pack(records)
	if self.password then
		chunk = compress.compress(chunk, "zlib", "fast", self.password)
	end
	local w = codec.writer()
	w:str(chunk)
	local data = w:done()
	if self.layout == "dir" then
		fs.makeDir(self.path, true)
	end
	fs.appendFile(self.journal, data)
	return #data
end

function Store:readJournal(): { any }
	local out = {}
	if not fs.isFile(self.journal) then
		return out
	end
	local r = codec.reader(fs.readFile(self.journal))
	while not r:eof() do
		local ok, chunk = pcall(r.str, r)
		if not ok then
			break
		end
		if self.password then
			chunk = compress.decompress(chunk, "zlib", MAX, self.password)
		end
		for _, rec in codec.unpack(chunk) do
			table.insert(out, rec)
		end
	end
	return out
end

return Store
