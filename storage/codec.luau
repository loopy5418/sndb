local codec = {}
-- Claude helped a lot for this file

local Writer = {}
Writer.__index = Writer

function codec.writer()
	return setmetatable({ b = buffer.create(1024), n = 0 }, Writer)
end

function Writer:grow(k: number)
	local need = self.n + k
	local size = buffer.len(self.b)
	if need > size then
		local b = buffer.create(math.max(need, size * 2))
		buffer.copy(b, 0, self.b, 0, self.n)
		self.b = b
	end
end

function Writer:u8(v: number)
	self:grow(1)
	buffer.writeu8(self.b, self.n, v)
	self.n += 1
end

function Writer:uint(v: number)
	self:grow(9)
	local b, n = self.b, self.n
	while v >= 128 do
		buffer.writeu8(b, n, v % 128 + 128)
		v //= 128
		n += 1
	end
	buffer.writeu8(b, n, v)
	self.n = n + 1
end

function Writer:int(v: number)
	self:uint(if v >= 0 then v * 2 else -v * 2 - 1)
end

function Writer:f64(v: number)
	self:grow(8)
	buffer.writef64(self.b, self.n, v)
	self.n += 8
end

function Writer:raw(s: string)
	self:grow(#s)
	buffer.writestring(self.b, self.n, s)
	self.n += #s
end

function Writer:str(s: string)
	self:uint(#s)
	self:raw(s)
end

function Writer:bits(vals: { any }, n: number, keep: (any) -> boolean)
	local bytes = (n + 7) // 8
	self:grow(bytes)
	local b, base = self.b, self.n
	buffer.fill(b, base, 0, bytes)
	for i = 1, n do
		if keep(vals[i]) then
			buffer.writebits(b, base * 8 + i - 1, 1, 1)
		end
	end
	self.n += bytes
end

local function keyOrder(a: any, b: any): boolean
	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return ta < tb
	elseif ta == "number" or ta == "string" then
		return a < b
	end
	return tostring(a) < tostring(b)
end

function Writer:any(v: any)
	local t = type(v)
	if v == nil then
		self:u8(0)
	elseif t == "boolean" then
		self:u8(if v then 2 else 1)
	elseif t == "number" then
		if v == math.floor(v) and math.abs(v) <= 2 ^ 52 then
			self:u8(3)
			self:int(v)
		else
			self:u8(4)
			self:f64(v)
		end
	elseif t == "string" then
		self:u8(5)
		self:str(v)
	elseif t == "table" then
		local n, count = #v, 0
		for _ in v do
			count += 1
		end
		if count == n then
			self:u8(6)
			self:uint(n)
			for i = 1, n do
				self:any(v[i])
			end
		else
			local keys = {}
			for k in v do
				table.insert(keys, k)
			end
			table.sort(keys, keyOrder)
			self:u8(7)
			self:uint(count)
			for _, k in keys do
				self:any(k)
				self:any(v[k])
			end
		end
	else
		error(`sndb: can't store a {t}`, 0)
	end
end

function Writer:done(): string
	return buffer.readstring(self.b, 0, self.n)
end

local Reader = {}
Reader.__index = Reader

function codec.reader(s: string)
	return setmetatable({ b = buffer.fromstring(s), n = 0, len = #s }, Reader)
end

function Reader:eof(): boolean
	return self.n >= self.len
end

function Reader:u8(): number
	local v = buffer.readu8(self.b, self.n)
	self.n += 1
	return v
end

function Reader:uint(): number
	local b, n, v, m = self.b, self.n, 0, 1
	while true do
		local x = buffer.readu8(b, n)
		n += 1
		v += (x % 128) * m
		if x < 128 then
			break
		end
		m *= 128
	end
	self.n = n
	return v
end

function Reader:int(): number
	local z = self:uint()
	return if z % 2 == 0 then z / 2 else -(z + 1) / 2
end

function Reader:f64(): number
	local v = buffer.readf64(self.b, self.n)
	self.n += 8
	return v
end

function Reader:raw(len: number): string
	if self.n + len > self.len then
		error("sndb: unexpected end of data", 0)
	end
	local s = buffer.readstring(self.b, self.n, len)
	self.n += len
	return s
end

function Reader:str(): string
	return self:raw(self:uint())
end

function Reader:bits(n: number): { boolean }
	local out, base = table.create(n), self.n * 8
	for i = 1, n do
		out[i] = buffer.readbits(self.b, base + i - 1, 1) == 1
	end
	self.n += (n + 7) // 8
	return out
end

function Reader:any(): any
	local tag = self:u8()
	if tag == 0 then
		return nil
	elseif tag <= 2 then
		return tag == 2
	elseif tag == 3 then
		return self:int()
	elseif tag == 4 then
		return self:f64()
	elseif tag == 5 then
		return self:str()
	elseif tag == 6 then
		local n = self:uint()
		local t = table.create(n)
		for i = 1, n do
			t[i] = self:any()
		end
		return t
	elseif tag == 7 then
		local t = {}
		for _ = 1, self:uint() do
			local k = self:any()
			t[k] = self:any()
		end
		return t
	end
	error("sndb: corrupt data", 0)
end

function codec.pack(v: any): string
	local w = codec.writer()
	w:any(v)
	return w:done()
end

function codec.unpack(s: string): any
	return codec.reader(s):any()
end

-- Column encoders: values are dense (no nils), m of them.
local scratch = buffer.create(4)

local function writeNums(w, xs, m)
	local ints, f32, prev = true, true, 0
	for i = 1, m do
		local x = xs[i]
		if ints and (x ~= math.floor(x) or math.abs(x - prev) > 2 ^ 51) then
			ints = false
		end
		prev = x
		if f32 then
			buffer.writef32(scratch, 0, x)
			f32 = buffer.readf32(scratch, 0) == x
		end
		if not ints and not f32 then
			break
		end
	end
	if ints then
		w:u8(0)
		prev = 0
		for i = 1, m do
			w:int(xs[i] - prev)
			prev = xs[i]
		end
	else
		local size = if f32 then 4 else 8
		w:u8(if f32 then 1 else 2)
		w:grow(m * size)
		local b, n = w.b, w.n
		for i = 1, m do
			if f32 then
				buffer.writef32(b, n, xs[i])
			else
				buffer.writef64(b, n, xs[i])
			end
			n += size
		end
		w.n = n
	end
end

local function readNums(r, m)
	local mode, out = r:u8(), table.create(m)
	if mode == 0 then
		local prev = 0
		for i = 1, m do
			prev += r:int()
			out[i] = prev
		end
	else
		local f32 = mode == 1
		for i = 1, m do
			if f32 then
				out[i] = buffer.readf32(r.b, r.n)
				r.n += 4
			else
				out[i] = r:f64()
			end
		end
	end
	return out
end

local function writeStrs(w, xs, m)
	local ids, order: { string }?, ids2 = {}, {}, table.create(m)
	for i = 1, m do
		local s = xs[i]
		local id = ids[s]
		if not id then
			local list = order :: { string }
			table.insert(list, s)
			if #list * 2 > m then
				order = nil
				break
			end
			id = #list
			ids[s] = id
		end
		ids2[i] = id
	end
	if order then
		w:u8(1)
		w:uint(#order)
		for _, s in order do
			w:str(s)
		end
		for i = 1, m do
			w:uint(ids2[i] - 1)
		end
	else
		w:u8(0)
		for i = 1, m do
			w:str(xs[i])
		end
	end
end

local function readStrs(r, m)
	local out = table.create(m)
	if r:u8() == 1 then
		local dict = {}
		for i = 1, r:uint() do
			dict[i] = r:str()
		end
		for i = 1, m do
			out[i] = dict[r:uint() + 1]
		end
	else
		for i = 1, m do
			out[i] = r:str()
		end
	end
	return out
end

local function truthy(v)
	return v == true
end

local function notNil(v)
	return v ~= nil
end

local writers = {
	int = writeNums,
	float = writeNums,
	string = writeStrs,
	blob = writeStrs,
	bool = function(w, xs, m)
		w:bits(xs, m, truthy)
	end,
	any = function(w, xs, m)
		for i = 1, m do
			w:any(xs[i])
		end
	end,
}

local readers = {
	int = readNums,
	float = readNums,
	string = readStrs,
	blob = readStrs,
	bool = function(r, m)
		return r:bits(m)
	end,
	any = function(r, m)
		local out = table.create(m)
		for i = 1, m do
			out[i] = r:any()
		end
		return out
	end,
}

function codec.writeColumn(w, kind: string, vals: { any }, n: number)
	local dense, m = table.create(n), 0
	for i = 1, n do
		local v = vals[i]
		if v ~= nil then
			m += 1
			dense[m] = v
		end
	end
	if m < n then
		w:u8(1)
		w:bits(vals, n, notNil)
	else
		w:u8(0)
	end
	writers[kind](w, dense, m)
end

function codec.readColumn(r, kind: string, n: number): { any }
	local present = if r:u8() == 1 then r:bits(n) else nil
	local m = n
	if present then
		m = 0
		for i = 1, n do
			if present[i] then
				m += 1
			end
		end
	end
	local dense = readers[kind](r, m)
	if not present then
		return dense
	end
	local out, j = table.create(n), 0
	for i = 1, n do
		if present[i] then
			j += 1
			out[i] = dense[j]
		end
	end
	return out
end

return codec
