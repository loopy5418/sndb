local util = require("../core/util")

export type Options = {
	columns: { string }?,
	fuzzy: (boolean | number)?,
	mode: ("all" | "any")?,
	weights: { [string]: number }?,
}

export type Spec = {
	cols: { string },
	terms: { string },
	dist: { number },
	all: boolean,
	weights: { [string]: number },
}

local search = {}

local WORD = "[^%s%p]+"

local function distance(a: string, b: string, max: number): number
	local la, lb = #a, #b
	if math.abs(la - lb) > max then
		return max + 1
	end
	local prev = table.create(lb + 1)
	for j = 0, lb do
		prev[j + 1] = j
	end
	for i = 1, la do
		local cur, best = { i }, i
		local ca = string.byte(a, i)
		for j = 1, lb do
			local v = math.min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (if ca == string.byte(b, j) then 0 else 1))
			cur[j + 1] = v
			if v < best then
				best = v
			end
		end
		if best > max then
			return max + 1
		end
		prev = cur
	end
	return prev[lb + 1]
end

function search.prepare(t: any, text: string, opts: Options?): Spec
	local o: Options = opts or {}
	local cols = o.columns
	if cols then
		for _, c in cols do
			if not t.byName[c] then
				util.fail("%s: unknown column '%s'", t.name, c)
			end
		end
	else
		cols = {}
		for _, c in t.columns do
			if c.type.kind == "string" or c.type.kind == "any" then
				table.insert(cols, c.name)
			end
		end
	end
	local terms, dist = {}, {}
	for w in string.gmatch(string.lower(text), WORD) do
		table.insert(terms, w)
		local f = o.fuzzy
		table.insert(dist, if type(f) == "number" then f elseif f then (if #w <= 4 then 1 else 2) else 0)
	end
	return { cols = cols :: { string }, terms = terms, dist = dist, all = o.mode ~= "any", weights = o.weights or {} }
end

local function text(v: any): string?
	if type(v) == "string" then
		return string.lower(v)
	elseif type(v) == "table" then
		local parts = {}
		for _, x in v do
			if type(x) == "string" or type(x) == "number" then
				table.insert(parts, string.lower(tostring(x)))
			end
		end
		return table.concat(parts, " ")
	end
	return nil
end

function search.score(spec: Spec, row: { [string]: any }): number
	local vals = {}
	for i, c in spec.cols do
		vals[i] = text(row[c]) or false
	end
	local total = 0
	for ti, term in spec.terms do
		local best, d = 0, spec.dist[ti]
		for i, s in vals do
			if s then
				local sc = 0
				local at = string.find(s, term, 1, true)
				if s == term then
					sc = 4
				elseif at then
					sc = if at == 1 or string.find(string.sub(s, at - 1, at - 1), "[%s%p]") then 2 else 1
				elseif d > 0 then
					for w in string.gmatch(s, WORD) do
						if distance(w, term, d) <= d then
							sc = 0.5
							break
						end
					end
				end
				sc *= spec.weights[spec.cols[i]] or 1
				if sc > best then
					best = sc
				end
			end
		end
		if best == 0 and spec.all then
			return 0
		end
		total += best
	end
	return total
end

function search.rank(t: any, rows: { any }, spec: Spec, sort: boolean): { any }
	if #spec.terms == 0 then
		return rows
	end
	local out, scores = {}, {}
	for _, r in rows do
		local s = search.score(spec, r)
		if s > 0 then
			table.insert(out, r)
			scores[r] = s
		end
	end
	if sort then
		local seq = t.seq
		table.sort(out, function(a, b)
			if scores[a] ~= scores[b] then
				return scores[a] > scores[b]
			end
			return seq[a] < seq[b]
		end)
	end
	return out
end

return search
