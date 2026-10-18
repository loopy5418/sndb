local crypto = require("@sonata/crypto")
local json = require("@sonata/json")
local binary = require("./binary")

type Snapshot = binary.Snapshot

local jsonfmt = {}

local function denull(v: any): any
	if v == json.null then
		return nil
	elseif type(v) == "table" then
		for k, x in v do
			v[k] = denull(x)
		end
	end
	return v
end

function jsonfmt.encode(snaps: { Snapshot }, pretty: boolean?): string
	local tables = json.object()
	for _, s in snaps do
		local rows = json.array()
		for i = 1, s.count do
			local row = json.object()
			for c, col in s.schema.columns do
				local v = s.cols[c][i]
				if v ~= nil and col.kind == "blob" then
					v = crypto.encode("base64", v)
				end
				row[col.name] = v
			end
			rows[i] = row
		end
		tables[s.name] = { schema = s.schema, rows = rows }
	end
	return json.encode({ sndb = 1, tables = tables }, if pretty then { indent = 2 } else nil)
end

function jsonfmt.decode(text: string): { Snapshot }
	local doc = json.decode(text)
	local snaps = {}
	for name, t in doc.tables do
		local schema = denull(t.schema)
		local cols = {}
		for c, col in schema.columns do
			local vals = table.create(#t.rows)
			for i, row in t.rows do
				local v = denull(row[col.name])
				if v ~= nil and col.kind == "blob" then
					v = crypto.decode("base64", v)
				end
				vals[i] = v
			end
			cols[c] = vals
		end
		table.insert(snaps, { name = name, schema = schema, count = #t.rows, cols = cols })
	end
	return snaps
end

return jsonfmt
