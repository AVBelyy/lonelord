_      = require "./_"
$      = require "underscore"
fs     = require "fs"
util   = require "util"
BSON   = require "buffalo"
sqlite = require "sqlite3"


[k, s] = [751, 8]
[low, high] = [1-k*s/2, k*s/2]

map = null
trees = []
mines = []
biomes = []
cliques = {}


F = (x) ->
    return [-((Math.floor(-x / (s/2)) + 1) >> 1), (s - 1 - (-x - s/2) % s) % s] if x < 0
    return [(Math.floor((x - 1) / (s/2)) + 1) >> 1, ((x - s/2 - 1) % s + s) % s] if x >= 0

backup = () ->
    fmt = (n) -> if n < 10 then "0#{n}" else n
    
    date = new Date
    filename = (1900 + date.getYear()) + (fmt date.getMonth() + 1) + (fmt date.getDate())
    buffer = BSON.serialize map
    fs.writeFileSync "backup/#{filename}.bson", buffer
    fs.unlinkSync "backup/current.bson" if fs.existsSync "backup/current.bson"
    fs.linkSync "backup/#{filename}.bson", "backup/current.bson"
    util.log "map backed up to #{filename}.bson"

generate = () ->
    # create map dictionary
    map = {}

    # generate empty map
    map[cluster] = Array s for cluster in [-(Math.floor k/2)..(Math.floor k/2)]

    # generate biomes
    start = low
    while start < high
        size = Math.min (Math.floor Math.random()*201 + 50), (high - start)
        biome = Math.floor Math.random()*3 + 100

        for x in [start..start+size]
            [i, j] = (F x)
            map[i][j] = [biome, _.VOID, {}]

        start += size

    # randomly place trees and mines
    for x in [-k*s/2+1..k*s/2]
        d_prob = if map[i][j][0] == _.DESERT then 100 else 200
        w_prob = if map[i][j][1] == _.PLAIN then 22 else 66

        if (Math.ceil Math.random() * d_prob) == d_prob
            [i, j] = (F x)
            if not map[i][j][1]
                map[i][j][1] = _.MINE
                map[i][j][2] =
                    qty: Math.floor Math.random()*1801 + 100 # gives integer number in [100; 1900]
                    ppl: []
                    all: 0

        [prob, qty] = [(Math.ceil Math.random() * w_prob), (Math.ceil Math.random() * 5)]
        if prob == w_prob
            for y in [x-qty+1..x]
                [i, j] = (F y)
                if not map[i][j][1] and map[i][j][0] != _.DESERT
                    map[i][j][1] = _.TREE
                    map[i][j][2] =
                        qty: (Math.floor Math.random()*76 + 25) * 1e3 # gives integer number in [25,000; 100,000]
                        ppl: []
                        all: 0

    backup()

load = () ->
    buffer = fs.readFileSync "backup/current.bson"
    BSON.parse buffer

if require.main is module and false
    # run directly
    generate()

    db = new sqlite.Database "lonelord.db"
    db.run "DELETE FROM users"
    db.run "DELETE FROM bots"
    db.run "DELETE FROM coffers"
    db.run "DELETE FROM log"
    fs.unlinkSync "backup/server.bson" if fs.existsSync "backup/server.bson"
else
    # included from server
    map = load()

    # let's determine every cluster's overwhelming biome
    # and also gather information about trees, mines and cliques' location
    $.each map, (cluster, i) ->
        C = [0, 0, 0]

        for [biome, obj, params], j in cluster
            C[biome-100]++

            if obj == _.TREE
                trees.push [i-0, j]
            if obj == _.MINE
                mines.push [i-0, j]
            if obj == _.FORUM
                cliques[params.cliques[0]] = [i-0, j]

        M = Math.max.apply null, C
        biomes[i] = 100 + C.indexOf M

exports.map = map
exports.trees = trees
exports.mines = mines
exports.biomes = biomes
exports.cliques = cliques
exports.k = k
exports.s = s
exports.low = low
exports.high = high
exports.F = F
exports.backup = backup
