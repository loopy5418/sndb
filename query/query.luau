local filters = require("./filters")
local search = require("./search")
local util = require("../core/util")

local fail, copy = util.fail, util.copy

local Query = {}
Query.__index = Query

function Query.new(t: any)
	return setmetatable({ t = t, groups = { {} }, orders = {}, off = 0, lim = nil, cols = nil, srch = nil }, Query)
end

function Query:_clone()
	local q = table.clone(self)
	q.groups = table.create(#self.groups)
	for i, g in self.groups do
		q.groups[i] = table.clone(g)
	end
	q.orders = table.clone(self.orders)
	return setmetatable(q, Query)
end

function Query:_conds(n: number, a: any, b: any, c: any): { filters.Cond }
	local t = self.t
	if type(a) == "function" then
		return { { pred = a } }
	elseif getmetatable(a) == Query then
		if a.t ~= t then
			fail("sub-query must be on the same table")
		end
		local groups = a.groups
		return {
			{
				pred = function(row)
					return filters.matches(groups, row)
				end,
			},
		}
	elseif type(a) == "table" then
		local out = {}
		for k, v in a do
			table.insert(out, filters.cond(t, k, v, nil, 2))
		end
		return out
	end
	return { filters.cond(t, a, b, c, n) }
end

function Query:_add(newGroup: boolean, negate: boolean, n: number, ...: any)
	local q = self:_clone()
	local conds = q:_conds(n, ...)
	if negate then
		local all = conds
		conds = {
			filters.negate({
				pred = function(row)
					return filters.matches({ all }, row)
				end,
			}),
		}
	end
	local groups = q.groups
	if newGroup and #groups[#groups] > 0 then
		table.insert(groups, {})
	end
	for _, c in conds do
		table.insert(groups[#groups], c)
	end
	return q
end

-- Filtering

function Query:where(...)
	return self:_add(false, false, select("#", ...), ...)
end

function Query:orWhere(...)
	return self:_add(true, false, select("#", ...), ...)
end

function Query:whereNot(...)
	return self:_add(false, true, select("#", ...), ...)
end

function Query:orWhereNot(...)
	return self:_add(true, true, select("#", ...), ...)
end

function Query:whereIn(col: string, list: { any })
	return self:where(col, "in", list)
end

function Query:whereNotIn(col: string, list: { any })
	return self:where(col, "notin", list)
end

function Query:whereBetween(col: string, lo: any, hi: any)
	return self:where(col, "between", { lo, hi })
end

function Query:whereNull(col: string)
	return self:where(col, "null", true)
end

function Query:whereNotNull(col: string)
	return self:where(col, "notnull", true)
end

function Query:search(text: string, opts: search.Options?)
	local q = self:_clone()
	q.srch = search.prepare(self.t, text, opts)
	return q
end

-- Shaping

function Query:orderBy(col: string | (any, any) -> boolean, dir: string?)
	local q = self:_clone()
	if type(col) == "function" then
		table.insert(q.orders, { fn = col })
	else
		local c = self.t.byName[col]
		if not c then
			fail("%s: unknown column '%s'", self.t.name, tostring(col))
		end
		table.insert(q.orders, { col = col, cmp = c.type.compare, desc = dir ~= nil and string.lower(dir) == "desc" })
	end
	return q
end

function Query:limit(n: number)
	local q = self:_clone()
	q.lim = n
	return q
end

function Query:offset(n: number)
	local q = self:_clone()
	q.off = n
	return q
end

function Query:page(n: number, size: number)
	return self:offset((n - 1) * size):limit(size)
end

function Query:select(...: string)
	local q = self:_clone()
	q.cols = { ... }
	for _, c in q.cols do
		if not self.t.byName[c] then
			fail("%s: unknown column '%s'", self.t.name, c)
		end
	end
	return q
end

-- Execution

function Query:_plan(): { any }?
	if #self.groups ~= 1 then
		return nil
	end
	local t = self.t
	for _, c in self.groups[1] do
		local idx = c.col and t.indexes[c.col]
		if idx and (c.op == "eq" or c.op == "in") then
			local out = {}
			for _, k in (if c.op == "eq" then { c.key } else c.keys) :: { any } do
				local hit = if k ~= nil then idx.map[k] else nil
				if hit and idx.unique then
					table.insert(out, hit)
				elseif hit then
					for r in hit do
						table.insert(out, r)
					end
				end
			end
			if #out > 1 then
				local seq = t.seq
				table.sort(out, function(a, b)
					return seq[a] < seq[b]
				end)
			end
			return out
		end
	end
	return nil
end

local function sorter(seq: { [any]: number }, orders: { any })
	return function(a, b)
		for _, o in orders do
			if o.fn then
				if o.fn(a, b) then
					return true
				elseif o.fn(b, a) then
					return false
				end
			else
				local x, y = a[o.col], b[o.col]
				if x ~= y then
					if x == nil then
						return false
					elseif y == nil then
						return true
					elseif o.cmp(x, y) then
						return not o.desc
					elseif o.cmp(y, x) then
						return o.desc
					end
				end
			end
		end
		return seq[a] < seq[b]
	end
end

function Query:_rows(): { any }
	local t = self.t
	local src = self:_plan() or t.rows
	local groups, out, n = self.groups, {}, 0
	local stop = if #self.orders == 0 and not self.srch and self.lim then self.off + self.lim else math.huge
	local all = #groups == 1 and #groups[1] == 0
	for _, row in src do
		if all or filters.matches(groups, row) then
			n += 1
			out[n] = row
			if n >= stop then
				break
			end
		end
	end
	if self.srch then
		out = search.rank(t, out, self.srch, #self.orders == 0)
	end
	if #self.orders > 0 then
		table.sort(out, sorter(t.seq, self.orders))
	end
	if self.off > 0 or self.lim then
		local first, last = self.off + 1, math.min(#out, self.off + (self.lim or math.huge))
		out = if first <= last then table.move(out, first, last, 1, {}) else {}
	end
	return out
end

function Query:get(): { { [string]: any } }
	local rows, cols = self:_rows(), self.cols
	for i, r in rows do
		rows[i] = copy(r, cols)
	end
	return rows
end
Query.all = Query.get

function Query:first(): { [string]: any }?
	return self:limit(1):get()[1]
end

function Query:count(): number
	if not self.lim and self.off == 0 and not self.srch and #self.groups == 1 and #self.groups[1] == 0 then
		return #self.t.rows
	end
	return #self:_rows()
end

function Query:exists(): boolean
	return self:limit(1):_rows()[1] ~= nil
end

function Query:each(fn: (row: { [string]: any }) -> ())
	for _, r in self:get() do
		fn(r)
	end
end

function Query:pluck(col: string): { any }
	local out = {}
	for _, r in self:_rows() do
		table.insert(out, util.deep(r[col]))
	end
	return out
end

function Query:sum(col: string): number
	local s = 0
	for _, r in self:_rows() do
		s += r[col] or 0
	end
	return s
end

function Query:avg(col: string): number?
	local s, n = 0, 0
	for _, r in self:_rows() do
		if r[col] ~= nil then
			s += r[col]
			n += 1
		end
	end
	return if n > 0 then s / n else nil
end

local function extreme(q, col: string, wantMax: boolean): any
	local c = q.t.byName[col] or fail("%s: unknown column '%s'", q.t.name, col)
	local cmp, best = c.type.compare, nil
	for _, r in q:_rows() do
		local v = r[col]
		if v ~= nil and (best == nil or (if wantMax then cmp(best, v) else cmp(v, best))) then
			best = v
		end
	end
	return util.deep(best)
end

function Query:min(col: string): any
	return extreme(self, col, false)
end

function Query:max(col: string): any
	return extreme(self, col, true)
end

function Query:distinct(col: string): { any }
	local c = self.t.byName[col] or fail("%s: unknown column '%s'", self.t.name, col)
	local key, seen, out = c.type.key, {}, {}
	for _, r in self:_rows() do
		local v = r[col]
		local k = if v ~= nil and key then key(v) else v
		if k ~= nil and not seen[k] then
			seen[k] = true
			table.insert(out, util.deep(v))
		end
	end
	return out
end

function Query:groupBy(col: string): { [any]: { { [string]: any } } }
	local out = {}
	for _, r in self:get() do
		local k = r[col]
		if k == nil then
			k = util.null
		end
		out[k] = out[k] or {}
		table.insert(out[k], r)
	end
	return out
end

function Query:countBy(col: string): { [any]: number }
	local out = {}
	for _, r in self:_rows() do
		local k = r[col]
		if k == nil then
			k = util.null
		end
		out[k] = (out[k] or 0) + 1
	end
	return out
end

function Query:paginate(page: number, size: number)
	local total = self:limit(math.huge):offset(0):count()
	return {
		items = self:page(page, size):get(),
		page = page,
		size = size,
		total = total,
		pages = math.max(1, math.ceil(total / size)),
	}
end

-- Mass editing. `changes` is a table (function values get `(old, row)` and return the new value),
-- or a function given a copy of the row that returns changes or edits the copy in place.
function Query:update(changes: { [string]: any } | (row: { [string]: any }) -> { [string]: any }?): number
	local t = self.t
	return t.db:_atomic(function()
		local rows = self:_rows()
		local computed = false
		if type(changes) == "table" then
			for _, v in changes do
				if type(v) == "function" then
					computed = true
				end
			end
		end
		for _, row in rows do
			if type(changes) == "function" then
				local cp = copy(row)
				local ch = changes(cp)
				t:_update(row, ch or cp, ch == nil)
			elseif computed then
				local cp, ch = copy(row), {}
				for k, v in changes do
					ch[k] = if type(v) == "function" then v(cp[k], cp) else v
				end
				t:_update(row, ch)
			else
				t:_update(row, changes)
			end
		end
		return #rows
	end)
end

function Query:increment(col: string, by: number?): number
	local n = by or 1
	return self:update({
		[col] = function(v)
			return (v or 0) + n
		end,
	})
end

function Query:decrement(col: string, by: number?): number
	return self:increment(col, -(by or 1))
end

function Query:delete(): number
	local t = self.t
	return t.db:_atomic(function()
		local rows = self:_rows()
		if #rows > 0 then
			local set = {}
			for _, r in rows do
				set[r] = true
			end
			t:_deleteMany(set)
		end
		return #rows
	end)
end

Query.methods = {
	"where",
	"orWhere",
	"whereNot",
	"orWhereNot",
	"whereIn",
	"whereNotIn",
	"whereBetween",
	"whereNull",
	"whereNotNull",
	"search",
	"orderBy",
	"limit",
	"offset",
	"page",
	"select",
	"all",
	"first",
	"count",
	"exists",
	"each",
	"pluck",
	"sum",
	"avg",
	"min",
	"max",
	"distinct",
	"groupBy",
	"countBy",
	"paginate",
	"increment",
	"decrement",
}

return Query
