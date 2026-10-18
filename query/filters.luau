local regex = require("@sonata/regex")
local util = require("../core/util")

local fail = util.fail

export type Cond = {
	pred: (row: { [string]: any }) -> boolean,
	col: string?,
	op: string?,
	key: any,
	keys: { any }?,
}

local filters = {}

local ALIASES = {
	["="] = "eq",
	["=="] = "eq",
	is = "eq",
	["!="] = "ne",
	["~="] = "ne",
	["<>"] = "ne",
	isnot = "ne",
	["<"] = "lt",
	["<="] = "le",
	lte = "le",
	[">"] = "gt",
	[">="] = "ge",
	gte = "ge",
	isnull = "null",
	isnotnull = "notnull",
	has = "contains",
} --when the aliases come out sizzling 🤑🤑🤑

local function likePattern(s: string, lower: boolean): string
	if lower then
		s = string.lower(s)
	end
	local p = string.gsub(s, "[%^%$%(%)%.%[%]%*%+%-%?%%_]", function(c)
		if c == "%" then
			return ".*"
		elseif c == "_" then
			return "."
		end
		return "%" .. c
	end)
	return "^" .. p .. "$"
end

local function contains(v: any, x: any, lower: boolean): boolean
	if type(v) == "string" then
		if lower then
			return string.find(string.lower(v), string.lower(x), 1, true) ~= nil
		end
		return string.find(v, x, 1, true) ~= nil
	elseif type(v) == "table" then
		for _, e in v do
			if e == x or (lower and type(e) == "string" and string.lower(e) == string.lower(x)) then
				return true
			end
		end
	end
	return false
end

-- Builds a predicate over a single value. "col" is the column definition, `val` the operan d.
local OPS: { [string]: (col: any, val: any, cond: Cond) -> (any) -> boolean }
OPS = {
	eq = function(col, val, cond)
		local key = col.type.key
		local k = if key then key(val) else val
		cond.key = k
		if key then
			return function(v)
				return v ~= nil and key(v) == k
			end
		end
		return function(v)
			return v == k
		end
	end,
	ne = function(col, val, cond)
		local eq = OPS.eq(col, val, cond)
		cond.key = nil
		return function(v)
			return not eq(v)
		end
	end,
	lt = function(col, val)
		local cmp = col.type.compare
		return function(v)
			return v ~= nil and cmp(v, val)
		end
	end,
	le = function(col, val)
		local cmp = col.type.compare
		return function(v)
			return v ~= nil and not cmp(val, v)
		end
	end,
	gt = function(col, val)
		local cmp = col.type.compare
		return function(v)
			return v ~= nil and cmp(val, v)
		end
	end,
	ge = function(col, val)
		local cmp = col.type.compare
		return function(v)
			return v ~= nil and not cmp(v, val)
		end
	end,
	["in"] = function(col, list, cond)
		if type(list) ~= "table" then
			fail("'in' needs a list")
		end
		local key, set, keys = col.type.key, {}, {}
		for _, x in list do
			local k = if key then key(x) else x
			if not set[k] then
				set[k] = true
				table.insert(keys, k)
			end
		end
		cond.keys = keys
		return function(v)
			return v ~= nil and set[if key then key(v) else v] == true
		end
	end,
	notin = function(col, list, cond)
		local isIn = OPS["in"](col, list, cond)
		cond.keys = nil
		return function(v)
			return not isIn(v)
		end
	end,
	between = function(col, range)
		local cmp, lo, hi = col.type.compare, range[1], range[2]
		return function(v)
			return v ~= nil and not cmp(v, lo) and not cmp(hi, v)
		end
	end,
	notbetween = function(col, range, cond)
		local inside = OPS.between(col, range, cond)
		return function(v)
			return v ~= nil and not inside(v)
		end
	end,
	like = function(_, s)
		local p = likePattern(s, false)
		return function(v)
			return type(v) == "string" and string.find(v, p) ~= nil
		end
	end,
	ilike = function(_, s)
		local p = likePattern(s, true)
		return function(v)
			return type(v) == "string" and string.find(string.lower(v), p) ~= nil
		end
	end,
	notlike = function(_, s)
		local p = likePattern(s, false)
		return function(v)
			return type(v) == "string" and string.find(v, p) == nil
		end
	end,
	contains = function(_, x)
		return function(v)
			return contains(v, x, false)
		end
	end,
	icontains = function(_, x)
		return function(v)
			return contains(v, x, true)
		end
	end,
	startswith = function(_, s)
		return function(v)
			return type(v) == "string" and string.sub(v, 1, #s) == s
		end
	end,
	endswith = function(_, s)
		return function(v)
			return type(v) == "string" and (s == "" or string.sub(v, -#s) == s)
		end
	end,
	match = function(_, p)
		return function(v)
			return type(v) == "string" and string.find(v, p) ~= nil
		end
	end,
	regex = function(_, p)
		return function(v)
			return type(v) == "string" and regex.test(v, p)
		end
	end,
	iregex = function(_, p)
		return function(v)
			return type(v) == "string" and regex.test(v, p, "i")
		end
	end,
	null = function()
		return function(v)
			return v == nil
		end
	end,
	notnull = function()
		return function(v)
			return v ~= nil
		end
	end,
}

local function coerce(col: any, val: any): any
	local c = col.type.coerce
	if not c or val == nil then
		return val
	elseif type(val) == "table" and not col.type.encode then
		local out = {}
		for k, x in val do
			out[k] = c(x)
		end
		return out
	end
	return c(val)
end

-- where(col, value) or where(col, op, value); a function value tests the column value.
function filters.cond(t: any, name: string, op: any, val: any, n: number): Cond
	local col = t.byName[name]
	if not col then
		fail("%s: unknown column '%s'", t.name, tostring(name))
	end
	if n == 2 then
		op, val = "eq", op
	end
	if type(op) == "function" then
		local f = op
		return {
			pred = function(row)
				return f(row[name]) == true
			end,
		}
	end
	if n == 2 and type(val) == "function" then
		local f = val
		return {
			pred = function(row)
				return f(row[name]) == true
			end,
		}
	end
	if type(op) ~= "string" then
		fail("invalid operator %s", tostring(op))
	end
	local key = string.lower((string.gsub(op, "[%s_]", "")))
	key = ALIASES[key] or key
	if not OPS[key] then
		fail("unknown operator '%s'", op)
	end
	local cond: Cond = { col = name, op = key, pred = nil :: any }
	local test = OPS[key](col, coerce(col, val), cond)
	cond.pred = function(row)
		return test(row[name])
	end
	return cond
end

function filters.negate(c: Cond): Cond
	local p = c.pred
	return {
		pred = function(row)
			return not p(row)
		end,
	}
end

function filters.matches(groups: { { Cond } }, row: { [string]: any }): boolean
	for _, g in groups do
		local ok = true
		for _, c in g do
			if not c.pred(row) then
				ok = false
				break
			end
		end
		if ok then
			return true
		end
	end
	return false
end

return filters
