local codec = require("./codec")

export type Snapshot = {
	name: string,
	schema: { columns: { { [string]: any } }, auto: number },
	count: number,
	cols: { { any } },
}

local binary = {}

function binary.encode(snaps: { Snapshot }): string
	local w = codec.writer()
	w:uint(#snaps)
	for _, s in snaps do
		w:str(s.name)
		w:any(s.schema)
		w:uint(s.count)
		for i, col in s.schema.columns do
			codec.writeColumn(w, col.kind, s.cols[i], s.count)
		end
	end
	return w:done()
end

function binary.decode(data: string): { Snapshot }
	local r = codec.reader(data)
	local snaps = {}
	for _ = 1, r:uint() do
		local s = { name = r:str(), schema = r:any(), count = 0, cols = {} }
		s.count = r:uint()
		for i, col in s.schema.columns do
			s.cols[i] = codec.readColumn(r, col.kind, s.count)
		end
		table.insert(snaps, s)
	end
	return snaps
end

return binary
