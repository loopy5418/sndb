local crypto = require("@sonata/crypto")
local datetime = require("@sonata/datetime")
local regex = require("@sonata/regex")
local codec = require("../storage/codec")
local util = require("../core/util")

local fail = util.fail

export type Type = {
	name: string,
	kind: string,
	args: { any }?,
	check: (any) -> (boolean, string?),
	compare: (any, any) -> boolean,
	coerce: ((any) -> any)?,
	encode: ((any) -> any)?,
	decode: ((any) -> any)?,
	key: ((any) -> any)?,
	generate: (() -> any)?,
}

export type Spec = {
	base: any?,
	check: ((any) -> (boolean, string?))?,
	compare: ((any, any) -> boolean)?,
	coerce: ((any) -> any)?,
	serialize: ((any) -> any)?,
	deserialize: ((any) -> any)?,
	generate: (() -> any)?,
}

local types = {}
local registry: { [string]: any } = {}

local function lt(a, b)
	return a < b
end

local function anyOrder(a, b)
	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return ta < tb
	elseif ta == "number" or ta == "string" then
		return a < b
	end
	return codec.pack(a) < codec.pack(b)
end

local function prim(name: string, kind: string, check: (any) -> boolean, extra: { [string]: any }?): Type
	local t = { name = name, kind = kind, check = check, compare = lt }
	if extra then
		for k, v in extra do
			t[k] = v
		end
	end
	return t :: any
end

function types.resolve(spec: any): Type
	if type(spec) == "table" and spec.check then
		return spec
	elseif type(spec) == "string" then
		local entry = registry[spec]
		if entry == nil then
			fail("unknown type '%s'", spec)
		elseif type(entry) == "function" then
			fail("type '%s' needs arguments", spec)
		end
		return entry
	elseif type(spec) == "table" and type(spec[1]) == "string" then
		local factory = registry[spec[1]]
		if type(factory) ~= "function" then
			fail("type '%s' takes no arguments", spec[1])
		end
		return factory(table.unpack(spec, 2))
	end
	return fail("invalid type %s", tostring(spec))
end

function types.spec(t: Type): any
	if not t.args then
		return t.name
	end
	local out = { t.name }
	for _, a in t.args do
		table.insert(out, if type(a) == "table" and a.check then types.spec(a) else a)
	end
	return out
end

local function derive(name: string, spec: Spec, args: { any }?): Type
	local base = types.resolve(spec.base or "any")
	local ser, de = spec.serialize, spec.deserialize
	local t: any = {
		name = name,
		args = args,
		kind = base.kind,
		coerce = spec.coerce or (not ser and base.coerce or nil),
		generate = spec.generate or (not ser and base.generate or nil),
	}
	if ser then
		if not de then
			fail("type '%s': serialize needs deserialize", name)
		end
		local benc, bdec, bkey = base.encode, base.decode, base.key
		t.check = spec.check or function()
			return true
		end
		t.encode = if benc then function(v)
			return benc(ser(v))
		end else ser
		t.decode = if bdec then function(p)
			return de(bdec(p))
		end else de
		t.key = if bkey then function(v)
			return bkey(ser(v))
		end else ser
		t.compare = spec.compare or function(a, b)
			return base.compare(ser(a), ser(b))
		end
	else
		local bcheck, check = base.check, spec.check
		t.check = if check
			then function(v)
				local ok, err = bcheck(v)
				if not ok then
					return false, err
				end
				return check(v)
			end
			else bcheck
		t.encode, t.decode, t.key = base.encode, base.decode, base.key
		t.compare = spec.compare or base.compare
	end
	return t
end

-- "spec" is a Spec, or a function taking type arguments and returning one
function types.define(name: string, spec: Spec | (...any) -> Spec)
	if not util.validName(name) then
		fail("invalid type name %s", tostring(name))
	end
	if type(spec) == "function" then
		registry[name] = function(...)
			return derive(name, spec(...), { ... })
		end
	else
		registry[name] = derive(name, spec)
	end
end

function types.get(name: string, ...: any): Type
	return if select("#", ...) > 0 then types.resolve({ name, ... }) else types.resolve(name)
end

function types.list(): { string }
	local out = {}
	for k in registry do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

registry.string = prim("string", "string", function(v)
	return type(v) == "string"
end)
registry.int = prim("int", "int", function(v)
	return type(v) == "number" and v == math.floor(v) and math.abs(v) <= 2 ^ 53
end)
registry.float = prim("float", "float", function(v)
	return type(v) == "number" and v == v
end)
registry.bool = prim("bool", "bool", function(v)
	return type(v) == "boolean"
end, {
	compare = function(a, b)
		return not a and b
	end,
})
registry.blob = prim("blob", "blob", function(v)
	return type(v) == "string"
end)
registry.any = prim("any", "any", function(v)
	local t = type(v)
	return t == "nil" or t == "boolean" or t == "number" or t == "string" or t == "table"
end, {
	compare = anyOrder,
	key = function(v)
		return if type(v) == "table" then codec.pack(v) else v
	end,
})

registry.text = registry.string
registry.integer = registry.int
registry.number = registry.float
registry.boolean = registry.bool
registry.json = registry.any

types.define("datetime", {
	base = "float",
	coerce = function(v)
		if type(v) == "string" then
			local t, ns = datetime.parse(v)
			return if t then t + (ns :: number) / 1e9 else v
		end
		return v
	end,
	generate = function()
		local t, ns = datetime.now()
		return t + ns / 1e9
	end,
})

types.define("uuid", {
	base = "string",
	check = function(v)
		return regex.matches(v, regex.patterns.uuid), "expected a uuid"
	end,
	generate = function()
		return crypto.uuid(7)
	end,
})

types.define("email", {
	base = "string",
	check = function(v)
		return regex.matches(v, regex.patterns.email), "expected an email address"
	end,
})

types.define("enum", function(...)
	local values = { ... }
	local pos = {}
	for i, v in values do
		pos[v] = i
	end
	return {
		base = "string",
		check = function(v)
			return pos[v] ~= nil, `expected one of {table.concat(values, ", ")}`
		end,
		compare = function(a, b)
			return pos[a] < pos[b]
		end,
	}
end)

types.define("array", function(of)
	local item = types.resolve(of or "any")
	local enc, dec = item.encode, item.decode
	local function map(f)
		return function(list)
			local out = table.create(#list)
			for i, v in list do
				out[i] = f(v)
			end
			return out
		end
	end
	return {
		base = "any",
		check = function(v)
			if type(v) ~= "table" then
				return false, "expected an array"
			end
			local n = 0
			for _, x in v do
				n += 1
				local ok, err = item.check(x)
				if not ok then
					return false, `item {n}: {err or "expected " .. item.name}`
				end
			end
			return n == #v, "expected an array"
		end,
		serialize = if enc then map(enc) else nil,
		deserialize = if dec then map(dec) else nil,
	}
end)

function types.enum(...: string): Type
	return types.get("enum", ...)
end

function types.array(of: any): Type
	return types.get("array", if type(of) == "table" and of.check then types.spec(of) else of)
end

return types
