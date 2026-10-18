local Query = require("../query/query")
local types = require("../types/registry")
local util = require("./util")

local fail, copy, deep, null = util.fail, util.copy, util.deep, util.null

export type Column = {
	name: string,
	type: types.Type,
	optional: boolean?,
	default: any,
	primary: boolean?,
	unique: boolean?,
	index: boolean?,
	auto: boolean?,
	min: number?,
	max: number?,
	pattern: string?,
	check: ((any) -> (boolean, string?))?,
}

local PERSISTED = { "optional", "primary", "unique", "index", "auto", "min", "max", "pattern" }

local Table = {}
Table.__index = Table

local function parseColumn(name: string, def: any): Column
	if not util.validName(name) then
		fail("invalid column name %s", tostring(name))
	end
	if type(def) == "string" or (type(def) == "table" and (def.check and def.kind or def[1])) then
		def = { type = def }
	elseif type(def) ~= "table" then
		fail("column '%s': invalid definition", name)
	end
	local c = table.clone(def)
	local ty = c.type
	if type(ty) == "string" and string.sub(ty, -1) == "?" then
		ty = string.sub(ty, 1, -2)
		c.optional = true
	end
	c.name = name
	c.type = types.resolve(ty)
	if c.primary then
		c.unique, c.optional = true, nil
	end
	if c.unique then
		c.index = true
	end
	if c.auto and c.type.kind ~= "int" and not c.type.generate then
		fail("column '%s': %s can't be auto", name, c.type.name)
	end
	return c :: any
end

local function persist(c: Column): { [string]: any }
	local out: { [string]: any } = { name = c.name, kind = c.type.kind, type = types.spec(c.type) }
	for _, k in PERSISTED do
		out[k] = (c :: any)[k]
	end
	if c.default ~= nil and type(c.default) ~= "function" then
		out.default = c.default
	end
	return out
end

function Table.new(db: any, name: string, defs: { [string]: any }, schema: any?)
	local self = setmetatable({
		db = db,
		name = name,
		columns = {} :: { Column },
		byName = {} :: { [string]: Column },
		rows = {},
		seq = {},
		nseq = 0,
		indexes = {},
		auto = 1,
		dirty = true,
	}, Table)
	if schema then
		for _, spec in schema.columns do
			local c = parseColumn(spec.name, spec)
			if c.type.kind ~= spec.kind then
				fail("%s.%s: stored as %s but type %s is %s", name, c.name, spec.kind, c.type.name, c.type.kind)
			end
			table.insert(self.columns, c)
		end
		self.auto = schema.auto or 1
	else
		local names = {}
		for k in defs do
			table.insert(names, k)
		end
		table.sort(names)
		for _, k in names do
			table.insert(self.columns, parseColumn(k, defs[k]))
		end
		local primaries = 0
		for _, c in self.columns do
			if c.primary then
				primaries += 1
			end
		end
		if primaries > 1 then
			fail("%s: only one primary column is allowed", name)
		elseif primaries == 0 then
			if defs.id ~= nil then
				fail("%s: column 'id' must be primary when no other column is", name)
			end
			table.insert(self.columns, parseColumn("id", { type = "int", primary = true, auto = true }))
		end
		table.sort(self.columns, function(a, b)
			if a.primary ~= b.primary then
				return a.primary == true
			end
			return a.name < b.name
		end)
	end
	self:_reindex()
	return self
end

function Table.load(db: any, snap: any)
	local self = Table.new(db, snap.name, {}, snap.schema)
	local rows, cols = self.rows, self.columns
	for i = 1, snap.count do
		rows[i] = {}
	end
	for ci, c in cols do
		local vals, dec, name = snap.cols[ci], c.type.decode, c.name
		for i = 1, snap.count do
			local v = vals[i]
			if v ~= nil and dec then
				v = dec(v)
			end
			rows[i][name] = v
		end
	end
	self:_reindex()
	self.dirty = false
	return self
end

-- Internals

function Table:_reindex()
	self.byName, self.indexes, self.autoCol = {}, {}, nil
	for _, c in self.columns do
		self.byName[c.name] = c
		if c.index then
			self.indexes[c.name] = { col = c, unique = c.unique == true, map = {} }
		end
		if c.auto and c.type.kind == "int" and not c.type.generate then
			if self.autoCol then
				fail("%s: only one auto-increment column is allowed", self.name)
			end
			self.autoCol = c
		end
		if c.primary then
			self.pk = c
		end
	end
	for _, row in self.rows do
		self:_unique(row)
		self:_index(row, true)
		if not self.seq[row] then
			self.nseq += 1
			self.seq[row] = self.nseq
		end
		self:_bump(row)
	end
end

local function keyOf(c: Column, v: any): any
	local k = c.type.key
	return if k then k(v) else v
end

function Table:_unique(row)
	for name, idx in self.indexes do
		local v = row[name]
		if idx.unique and v ~= nil then
			local other = idx.map[keyOf(idx.col, v)]
			if other and other ~= row then
				fail("%s.%s: duplicate value %s", self.name, name, tostring(v))
			end
		end
	end
end

function Table:_index(row, add: boolean)
	for name, idx in self.indexes do
		local v = row[name]
		if v ~= nil then
			local k, map = keyOf(idx.col, v), idx.map
			if idx.unique then
				map[k] = if add then row else nil
			elseif add then
				local set = map[k]
				if not set then
					set = {}
					map[k] = set
				end
				set[row] = true
			elseif map[k] then
				map[k][row] = nil
				if next(map[k]) == nil then
					map[k] = nil
				end
			end
		end
	end
end

function Table:_bump(row)
	local a = self.autoCol
	local v = a and row[a.name]
	if v and v >= self.auto then
		self.auto = v + 1
	end
end

function Table:_log(undo: (() -> ())?, rec: any?)
	local log = self.db._log
	if log then
		table.insert(log, { undo = undo, rec = rec })
	end
	self.dirty = true
end

function Table:_enc(row): { [string]: any }
	local out = {}
	for _, c in self.columns do
		local v, enc = row[c.name], c.type.encode
		out[c.name] = if v ~= nil and enc then enc(v) else v
	end
	return out
end

function Table:_dec(enc): { [string]: any }
	local out = {}
	for _, c in self.columns do
		local v, dec = enc[c.name], c.type.decode
		out[c.name] = if v ~= nil and dec then dec(v) else v
	end
	return out
end

function Table:_byPk(v: any)
	return if v == nil then nil else self.indexes[self.pk.name].map[keyOf(self.pk, v)]
end

function Table:_check(c: Column, v: any): any
	if v == nil then
		if c.optional then
			return nil
		end
		fail("%s.%s is required", self.name, c.name)
	end
	local t = c.type
	if t.coerce then
		v = t.coerce(v)
	end
	local ok, err = t.check(v)
	if not ok then
		fail("%s.%s: %s", self.name, c.name, err or `expected {t.name}, got {typeof(v)}`)
	end
	if c.min or c.max then
		local size = if type(v) == "number" then v elseif type(v) == "string" or type(v) == "table" then #v else nil
		if size and c.min and size < c.min then
			fail("%s.%s: %s is below the minimum of %s", self.name, c.name, tostring(size), tostring(c.min))
		elseif size and c.max and size > c.max then
			fail("%s.%s: %s is above the maximum of %s", self.name, c.name, tostring(size), tostring(c.max))
		end
	end
	if c.pattern and (type(v) ~= "string" or not string.find(v, c.pattern)) then
		fail("%s.%s: doesn't match the pattern %s", self.name, c.name, c.pattern)
	end
	if c.check then
		local ok2, err2 = c.check(v)
		if not ok2 then
			fail("%s.%s: %s", self.name, c.name, err2 or "check failed")
		end
	end
	return if type(v) == "table" then deep(v) else v
end

function Table:_fill(c: Column): any
	if c.auto then
		return if c.type.generate then c.type.generate() else self.auto
	elseif type(c.default) == "function" then
		return c.default()
	end
	return deep(c.default)
end

function Table:_build(input: { [string]: any }): { [string]: any }
	if type(input) ~= "table" then
		fail("%s: a row must be a table", self.name)
	end
	for k in input do
		if not self.byName[k] then
			fail("%s: unknown column '%s'", self.name, tostring(k))
		end
	end
	local row = {}
	for _, c in self.columns do
		local v = input[c.name]
		if v == null then
			v = nil
		elseif v == nil then
			v = self:_fill(c)
		end
		row[c.name] = self:_check(c, v)
	end
	return row
end

function Table:_add(row, pos: number?, seq: number?)
	self:_unique(row)
	self:_index(row, true)
	if pos then
		table.insert(self.rows, pos, row)
	else
		table.insert(self.rows, row)
	end
	if not seq then
		self.nseq += 1
		seq = self.nseq
	end
	self.seq[row] = seq
	self:_bump(row)
end

function Table:_insert(input)
	local row = self:_build(input)
	self:_add(row)
	self:_log(function()
		self:_deleteMany({ [row] = true }, true)
	end, { "i", self.name, self:_enc(row) })
	return row
end

-- Replaces a row's values with "vals" (a complete row)
function Table:_set(row, vals, quiet: boolean?)
	local old, oldPk = table.clone(row), row[self.pk.name]
	for name, idx in self.indexes do
		local v = vals[name]
		if idx.unique and v ~= nil then
			local other = idx.map[keyOf(idx.col, v)]
			if other and other ~= row then
				fail("%s.%s: duplicate value %s", self.name, name, tostring(v))
			end
		end
	end
	self:_index(row, false)
	table.clear(row)
	for k, v in vals do
		row[k] = v
	end
	self:_index(row, true)
	if not quiet then
		self:_log(function()
			self:_set(row, old, true)
		end, { "u", self.name, self:_encPk(oldPk), self:_enc(row) })
	end
end

function Table:_encPk(v)
	local enc = self.pk.type.encode
	return if enc then enc(v) else v
end

function Table:_update(row, changes, full: boolean?)
	if type(changes) ~= "table" then
		fail("%s: changes must be a table", self.name)
	end
	local vals = if full then {} else table.clone(row)
	for k, v in changes do
		local c = self.byName[k] or fail("%s: unknown column '%s'", self.name, tostring(k))
		vals[k] = if v == null then nil else v
		if not full then
			vals[k] = self:_check(c, vals[k])
		end
	end
	if full then
		for _, c in self.columns do
			vals[c.name] = self:_check(c, vals[c.name])
		end
	end
	self:_set(row, vals)
end

function Table:_deleteMany(set: { [any]: boolean }, quiet: boolean?)
	local kept, removed = {}, {}
	for i, r in self.rows do
		if set[r] then
			table.insert(removed, { i, r, self.seq[r] })
			self:_index(r, false)
			self.seq[r] = nil
			if not quiet then
				self:_log(nil, { "d", self.name, self:_encPk(r[self.pk.name]) })
			end
		else
			table.insert(kept, r)
		end
	end
	self.rows = kept
	if not quiet then
		self:_log(function()
			for _, e in removed do
				self:_add(e[2], e[1], e[3])
			end
		end)
	end
	self.dirty = true
end

function Table:_schema(fn: () -> ())
	local cols = table.clone(self.columns)
	local auto, vals = self.auto, table.create(#self.rows)
	for i, r in self.rows do
		vals[i] = { r, table.clone(r) }
	end
	self:_log(function()
		self.columns, self.auto = cols, auto
		for _, e in vals do
			table.clear(e[1])
			for k, v in e[2] do
				e[1][k] = v
			end
		end
		self:_reindex()
	end)
	self.db._schemaChanged = true
	fn()
	self:_reindex()
end

function Table:_dump()
	local n, cols = #self.rows, {}
	for ci, c in self.columns do
		local vals, enc, name = table.create(n), c.type.encode, c.name
		for i, row in self.rows do
			local v = row[name]
			vals[i] = if v ~= nil and enc then enc(v) else v
		end
		cols[ci] = vals
	end
	local specs = {}
	for i, c in self.columns do
		specs[i] = persist(c)
	end
	return { name = self.name, schema = { columns = specs, auto = self.auto }, count = n, cols = cols }
end

-- Adds missing columns and re-attaches runtime-only options (check functions, function defaults).
function Table:_merge(defs: { [string]: any })
	for name, def in defs do
		local c = self.byName[name]
		if not c then
			self:addColumn(name, def)
		elseif type(def) == "table" and not def.kind and not def[1] then
			c.check = def.check
			if type(def.default) == "function" then
				c.default = def.default
			end
		end
	end
end

-- Rows

function Table:insert(row: { [string]: any }): { [string]: any }
	return self.db:_atomic(function()
		return copy(self:_insert(row))
	end)
end

function Table:insertMany(rows: { { [string]: any } }): { { [string]: any } }
	return self.db:_atomic(function()
		local out = table.create(#rows)
		for i, r in rows do
			out[i] = copy(self:_insert(r))
		end
		return out
	end)
end

function Table:get(pk: any): { [string]: any }?
	local row = self:_byPk(pk)
	return if row then copy(row) else nil
end

function Table:has(pk: any): boolean
	return self:_byPk(pk) ~= nil
end

function Table:update(pk: any, changes: { [string]: any }): { [string]: any }
	return self.db:_atomic(function()
		local row = self:_byPk(pk) or fail("%s: no row with %s = %s", self.name, self.pk.name, tostring(pk))
		self:_update(row, changes)
		return copy(row)
	end)
end

-- Updates the row whose `on` column (default: the primary key) matches, or inserts it.
function Table:upsert(input: { [string]: any }, on: string?): { [string]: any }
	return self.db:_atomic(function()
		local col = on or self.pk.name
		local idx = self.indexes[col]
		local v = input[col]
		local row
		if idx and idx.unique then
			row = if v ~= nil then idx.map[keyOf(idx.col, v)] else nil
		elseif v ~= nil then
			row = Query.new(self):where(col, v):_rows()[1]
		end
		if row then
			self:_update(row, input)
		else
			row = self:_insert(input)
		end
		return copy(row)
	end)
end

function Table:delete(pk: any): boolean
	return self.db:_atomic(function()
		local row = self:_byPk(pk)
		if row then
			self:_deleteMany({ [row] = true })
		end
		return row ~= nil
	end)
end

function Table:clear(): number
	return Query.new(self):delete()
end

function Table:query()
	return Query.new(self)
end

-- Schema

function Table:columnList(): { { [string]: any } }
	local out = {}
	for i, c in self.columns do
		out[i] = persist(c)
	end
	return out
end

function Table:addColumn(name: string, def: any)
	self.db:_atomic(function()
		if self.byName[name] then
			fail("%s: column '%s' already exists", self.name, name)
		end
		local c = parseColumn(name, def)
		if c.primary then
			fail("%s: can't add a second primary column", self.name)
		end
		self:_schema(function()
			table.insert(self.columns, c)
			for _, row in self.rows do
				row[name] = self:_check(c, self:_fill(c))
				if c.auto and not c.type.generate then
					self.auto += 1
				end
			end
		end)
	end)
end

function Table:dropColumn(name: string)
	self.db:_atomic(function()
		local c = self.byName[name] or fail("%s: unknown column '%s'", self.name, name)
		if c.primary then
			fail("%s: can't drop the primary column", self.name)
		end
		self:_schema(function()
			table.remove(self.columns, table.find(self.columns, c))
			for _, row in self.rows do
				row[name] = nil
			end
		end)
	end)
end

function Table:renameColumn(from: string, to: string)
	self.db:_atomic(function()
		local c = self.byName[from] or fail("%s: unknown column '%s'", self.name, from)
		if not util.validName(to) or self.byName[to] then
			fail("%s: can't rename '%s' to '%s'", self.name, from, tostring(to))
		end
		self:_schema(function()
			local nc = table.clone(c)
			nc.name = to
			self.columns[table.find(self.columns, c) :: number] = nc
			for _, row in self.rows do
				row[to], row[from] = row[from], nil
			end
		end)
	end)
end

-- Changes a column's definition, revalidating every value (optionally converted first)
function Table:alterColumn(name: string, def: any, convert: ((any, { [string]: any }) -> any)?)
	self.db:_atomic(function()
		local c = self.byName[name] or fail("%s: unknown column '%s'", self.name, name)
		local nc = parseColumn(name, def)
		if (c.primary == true) ~= (nc.primary == true) then
			fail("%s: can't change which column is primary", self.name)
		end
		self:_schema(function()
			self.columns[table.find(self.columns, c) :: number] = nc
			for _, row in self.rows do
				local v = row[name]
				if convert then
					v = convert(v, copy(row))
				end
				if v == nil and not nc.optional then
					v = self:_fill(nc)
				end
				row[name] = self:_check(nc, v)
			end
		end)
	end)
end

function Table:createIndex(name: string, unique: boolean?)
	self.db:_atomic(function()
		local c = self.byName[name] or fail("%s: unknown column '%s'", self.name, name)
		self:_schema(function()
			local nc = table.clone(c)
			nc.index, nc.unique = true, unique or c.unique
			self.columns[table.find(self.columns, c) :: number] = nc
		end)
	end)
end

function Table:dropIndex(name: string)
	self.db:_atomic(function()
		local c = self.byName[name] or fail("%s: unknown column '%s'", self.name, name)
		if c.primary then
			fail("%s: can't drop the primary key index", self.name)
		end
		self:_schema(function()
			local nc = table.clone(c)
			nc.index, nc.unique = nil, nil
			self.columns[table.find(self.columns, c) :: number] = nc
		end)
	end)
end

for _, m in Query.methods do
	if Table[m] == nil then
		Table[m] = function(self, ...)
			local q = Query.new(self)
			return q[m](q, ...)
		end
	end
end

return Table
