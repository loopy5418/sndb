local Database = require("./core/database")
local types = require("./types/registry")
local util = require("./core/util")

local sndb = {
	version = "0.1.0",
	null = util.null,
	types = types,
	define = types.define,
	type = types.get,
	enum = types.enum,
	array = types.array,
}

-- every function, method etc. is defined in the database object
function sndb.open(path: string, opts: Database.Options?)
	return Database.open(path, opts)
end

function sndb.memory()
	return Database.open(nil)
end

return sndb
