local Store = require("../storage/store")
local Table = require("./table")
local util = require("./util")

local fail = util.fail

export type Options = Store.Options & {
	sync: ("journal" | "full" | "manual")?,
	journalLimit: number?,
}

local Database = {}
local methods = {}

Database.__index = function(self, k)
	return methods[k] or (rawget(self, "_tables") :: any)[k]
end

function Database.open(path: string?, opts: Options?)
	local o: Options = opts or {}
	local sync = o.sync or "journal"
	if sync ~= "journal" and sync ~= "full" and sync ~= "manual" then
		fail("unknown sync mode '%s'", tostring(sync))
	end
	local self = setmetatable({
		_tables = {},
		_store = if path then Store.new(path, o) else nil,
		_sync = sync,
		_limit = o.journalLimit or 4 * 1024 * 1024,
		_journal = 0,
		_schemaChanged = false,
	}, Database)
	if self._store then
		self:_load()
	end
	return self
end

function methods:_load()
	local snaps, records = self._store:load()
	for _, s in snaps do
		self._tables[s.name] = Table.load(self, s)
	end
	for _, rec in records do
		local t = self._tables[rec[2]]
		if t then
			if rec[1] == "i" then
				t:_add(t:_dec(rec[3]))
			else
				local dec = t.pk.type.decode
				local row = t:_byPk(if dec then dec(rec[3]) else rec[3])
				if row and rec[1] == "u" then
					t:_set(row, t:_dec(rec[4]), true)
				elseif row then
					t:_deleteMany({ [row] = true }, true)
				end
			end
		end
	end
	if #records > 0 then
		self:save()
	end
end

-- Runs fn so that either all of its changes apply or none do; nested calls act as savepoints
function methods:_atomic(fn: (...any) -> ...any, ...: any): ...any
	local outer = self._log
	local log = outer or {}
	local mark = #log
	self._log = log
	local res = table.pack(pcall(fn, ...))
	if not res[1] then
		self._log = nil
		for i = #log, mark + 1, -1 do
			local undo = log[i].undo
			if undo then
				undo()
			end
			log[i] = nil
		end
		self._log = outer
		error(res[2], 0)
	end
	if not outer then
		self._log = nil
		self:_commit(log)
	end
	return table.unpack(res, 2, res.n)
end

function methods:_commit(log: { any })
	local store = self._store
	if not store or self._sync == "manual" or #log == 0 then
		return
	elseif self._sync == "full" or self._schemaChanged then
		self:save()
		return
	end
	local recs = {}
	for _, e in log do
		if e.rec then
			table.insert(recs, e.rec)
		end
	end
	if #recs > 0 then
		self._journal += store:append(recs)
		if self._journal > self._limit then
			self:save()
		end
	end
end

function methods:transaction(fn: (db: any) -> ...any): ...any
	return self:_atomic(fn, self)
end

function methods:createTable(name: string, columns: { [string]: any }?)
	return self:_atomic(function()
		if type(name) ~= "string" or not string.match(name, "^%a[%w_]*$") then
			fail("invalid table name %s", tostring(name))
		elseif self._tables[name] then
			fail("table '%s' already exists", name)
		end
		local t = Table.new(self, name, columns or {})
		self._tables[name] = t
		self._schemaChanged = true
		table.insert(self._log, {
			undo = function()
				self._tables[name] = nil
			end,
		})
		return t
	end)
end

-- Returns a table, creating it from "columns" if needed (existing tables gain any new columns)
function methods:table(name: string, columns: { [string]: any }?)
	local t = self._tables[name]
	if t then
		if columns then
			t:_merge(columns)
		end
		return t
	elseif not columns then
		fail("no table named '%s'", tostring(name))
	end
	return self:createTable(name, columns)
end

function methods:hasTable(name: string): boolean
	return self._tables[name] ~= nil
end

function methods:tables(): { string }
	local out = {}
	for name in self._tables do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

function methods:dropTable(name: string)
	self:_atomic(function()
		local t = self._tables[name] or fail("no table named '%s'", tostring(name))
		self._tables[name] = nil
		self._schemaChanged = true
		table.insert(self._log, {
			undo = function()
				self._tables[name] = t
			end,
		})
	end)
end

function methods:renameTable(from: string, to: string)
	self:_atomic(function()
		local t = self._tables[from] or fail("no table named '%s'", tostring(from))
		if type(to) ~= "string" or not string.match(to, "^%a[%w_]*$") or self._tables[to] then
			fail("can't rename '%s' to '%s'", from, tostring(to))
		end
		self._tables[from], self._tables[to], t.name, t.dirty = nil, t, to, true
		self._schemaChanged = true
		table.insert(self._log, {
			undo = function()
				self._tables[to], self._tables[from], t.name = nil, t, from
			end,
		})
	end)
end

function methods:save()
	if self._log then
		fail("can't save inside a transaction")
	end
	if self._store then
		self._store:save(self._tables)
		for _, t in self._tables do
			t.dirty = false
		end
		self._journal, self._schemaChanged = 0, false
	end
end

-- Writes a full copy elsewhere, in any format (also how an in-memory database gets saved)
function methods:backup(path: string, opts: Store.Options?)
	Store.new(path, opts or {}):save(self._tables, true)
end

function methods:close()
	if self._store then
		local dirty = self._journal > 0 or self._schemaChanged
		for _, t in self._tables do
			dirty = dirty or t.dirty
		end
		if dirty then
			self:save()
		end
	end
end

function methods:stats()
	local store = self._store
	local out = { tables = {}, sync = self._sync, journal = self._journal }
	if store then
		out.path, out.layout = store.path, store.layout
		out.format, out.compression = store:settings()
	end
	for name, t in self._tables do
		out.tables[name] = { rows = #t.rows, columns = #t.columns }
	end
	return out
end

return Database
