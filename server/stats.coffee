_   = require "./_"
$    = require "underscore"
fs   = require "fs"
map = require "./map"

biomes = [0, 0, 0]

diamonds = num: 0, mined: 0, qty: 0
forests  = num: 0, mined: 0, qty: 0

towers_cnt = castles_cnt = markets_cnt = forums_cnt = 0

where_to_flee = (i, j, login) ->
    walk = (x) ->
        while true
            j += x
            if j == -1
                i -= 1
                j = map.s - 1
            if j == map.s
                i += 1
                j = 0
            return [9999] if (Math.abs 2*i) > map.k
            return [i, j] if map.map[i][j][1] in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM] and \
                             map.map[i][j][2].owner == login

    [il, jl] = walk -1
    [ir, jr] = walk +1

    if (Math.abs i - il) < (Math.abs i - ir) then [il, jl] else [ir, jr]

binSearch = (A, p) ->
    [l, r] = [0, A.length - 1]

    while l < r
        m = Math.floor (l + r)/2
        [l, r] = if p < A[m] then [l, m] else [m, r]
        return l if r - l == 1 and A[l] <= p < A[r]

Max =
    m: 0, M: 0
    f: 0, F: 0
    w: 0, W: 0
    d: 0, D: 0
    p: 0, P: 0
    l: 0, L: 0
    mf: 0, MF: 0
    ff: 0, FF: 0

Rs = []
RD = 0
$.each map.map, (cluster, i) ->
    for object, j in cluster
        id = 8*i + j - 3
        if object[2].qty? and isNaN object[2].qty
            console.log "NaN: #{id}"
        if object[2].owner == "krendelkoph"
            console.log id
            RD += object[2].d
        if object[2].owner and not object[2].cliques
            console.log "--> #{id}"
        if object[2].d
            Rs.push [object[2].d, id, object[2].owner]
        biomes[object[0]-100]++
        if Max.m < object[2].m and i != "0"
            Max.m = object[2].m
            Max.M = id
        if Max.f < object[2].f and i != "0"
            Max.f = object[2].f
            Max.F = id
        if Max.w < object[2].w and i != "0"
            Max.w = object[2].w
            Max.W = id
        if Max.d < object[2].d and i != "0"
            Max.d = object[2].d
            Max.D = id
        if Max.p < object[2].all and i != "0"
            Max.p = object[2].all
            Max.P = id
        if Max.l < object[2].lvl and id % 500 != 0 and i != "0"
            Max.l = object[2].lvl
            Max.L = id
        if Max.mf < object[2].mf and i != "0"
            Max.mf = object[2].mf
            Max.MF = id
        if Max.ff < object[2].ff and i != "0"
            Max.ff = object[2].ff
            Max.FF = id
        if -3000 <= id <= 3000
            switch object[1]
                when _.TOWER
                    towers_cnt += 1
                when _.CASTLE
                    castles_cnt += 1
                when _.MARKET
                    markets_cnt += 1
                when _.FORUM
                    forums_cnt += 1
                when _.MINE
                    diamonds.num += 1
                    diamonds.mined += 1 if (1 for [x, y, z] in object[2].ppl when z >= 200).length > 0
                    diamonds.qty += object[2].qty
                when _.TREE
                    forests.num += 1
                    forests.mined += 1 if object[2].all > 0
                    forests.qty += object[2].qty

Rs.sort ([p1], [p2]) -> p2 - p1
console.log "Diamonds of someone: #{RD}"
console.log "Riches:"
for i in [1..10]
    console.log "    #{Rs[i][1]}: #{Rs[i][0]} (#{Rs[i][2]})"

out = []
x = y = й = 0
trees_parsed = []
trees_parsed.push 8 * i + j - 3 for [i, j] in map.trees
trees_parsed.sort (a, b) -> a - b
mines_parsed = []
mines_parsed.push 8 * i + j - 3 for [i, j] in map.mines
mines_parsed.sort (a, b) -> a - b
while true
        idx = trees_parsed[x] or 100500
        idy = mines_parsed[y] or 100500
        if idx < idy
            out[й++] = idx
            x++
        else if idx > idy
            out[й++] = idy
            y++
        else
            break

D_ = {}
D  = []
for I in [0..out.length - 2]
    x = Math.ceil (out[I+1] - out[I]) / 2
    continue if out[I+1] - out[I] == 1
    D_[x] = (D_[x] or 0) + 1
    for x_ in [x-1..1]
        D_[x_] = (D_[x_] or 0) + 2
n = d = 0
$.each D_, (v, k) ->
    D.push [k, v]
    n += k*v
    d += v
D.sort ([k1, v1], [k2, v2]) -> k1 - k2

console.log "avg nearest resource=#{n/d}"
console.log "map items where nearest resource farther then 100=#{$.reduce (v for [k, v] in D when k >= 100), (a, b) -> a + b}"

size = biomes[0] + biomes[1] + biomes[2]

console.log "Biomes: #{Math.floor biomes[0] / size*100}% / #{Math.floor biomes[1] / size*100}% / #{Math.floor biomes[2] / size*100}%"

console.log "Diamonds: #{diamonds.mined}(#{diamonds.num}) / #{diamonds.qty} (#{Math.floor diamonds.qty/(diamonds.mined*4)} days)"
console.log "Forests:  #{forests.mined}(#{forests.num}) / #{forests.qty} (#{Math.floor forests.qty/(forests.mined*24*20)} days)"

console.log "Buildings: towers=#{towers_cnt}, castles=#{castles_cnt}, markets=#{markets_cnt}, forums=#{forums_cnt}"
console.log "Maximum: money=#{Max.m}(##{Max.M}), fuel=#{Max.f}(##{Max.F}), wood=#{Max.w}(##{Max.W}), diamonds=#{Max.d}(##{Max.D}), people=#{Max.p}(##{Max.P})"
console.log "         lvl=#{Max.l}(##{Max.L}), mf=#{Max.mf}(##{Max.MF}), ff=#{Max.ff}(##{Max.FF})"
