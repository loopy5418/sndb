local util = {}

util.null = table.freeze(setmetatable({}, {
	__tostring = function()
		return "sndb.null"
	end,
}))

function util.fail(msg: string, ...: any): never
	error("sndb: " .. string.format(msg, ...), 0)
end

local function deep(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local c = {}
	for k, x in v do
		c[k] = deep(x)
	end
	return setmetatable(c, getmetatable(v))
end
util.deep = deep

function util.copy(row: { [string]: any }, cols: { string }?): { [string]: any }
	local c
	if cols then
		c = {}
		for _, k in cols do
			c[k] = row[k]
		end
	else
		c = table.clone(row)
	end
	for k, v in c do
		if type(v) == "table" then
			c[k] = deep(v)
		end
	end
	return c
end

function util.validName(name: any): boolean
	return type(name) == "string" and string.match(name, "^[%a_][%w_]*$") ~= nil
end

return util
