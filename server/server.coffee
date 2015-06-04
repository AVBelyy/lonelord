login_regexp = /^\w{2,32}$/
int_regexp   = /^\-?\d+$/

trade_regexp  = /^(\d*)([mfwdg])\s*\/\s*(\d*)([mfwdg])$/


$           = require "underscore"
fs          = require "fs"
net         = require "net"
BSON        = require "buffalo"
util        = require "util"
gzippo      = require "gzippo"
crypto      = require "crypto"
sqlite      = require "sqlite3"
logger      = require "morgan"
express     = require "express"
body_parser = require "body-parser"

_     = require "./_"
map   = require "./map"
mail  = require "./mail"


db = new sqlite.Database "lonelord.db"

onliners = {}
days = 0
mines_check = ([0, 0] for x in [1..map.mines.length])


exports.get_db = () -> db
log = require "./log"


error = (code)    -> {status: "error", data: code}
wait = (sec)      -> error "try again in #{(Math.ceil sec / 100) / 10} seconds"
ok = (data)       -> {status: "ok", data: data}
defeat = (data)   -> {status: "defeat", casualties: data}
victory = (data)  -> {status: "victory", casualties: data}
md5 = (string)    -> ((crypto.createHash "md5").update string.toString()).digest "hex"
hash = (password) -> md5 "lone" + (md5 password) + "lord"
timestamp = ()    -> Math.floor new Date().getTime() / 1000
is_str = (sth)    -> typeof sth == "string"
is_qty = (sth)    -> not (isNaN sth) and ((parseInt sth) == (parseFloat sth)) and (sth >= 0)
set_time = (kuki) -> onliners[kuki].when = new Date().getTime() + (if kuki.length == 16 then 60 else 2)*1000 if onliners[kuki]

trimmed_hash = (str) ->
    h_str = hash str
    h_str[0] + h_str[1] + h_str[2] + h_str[4] + h_str[6] + h_str[10] + h_str[12] + h_str[16] + h_str[18] + h_str[28]

sanitize = (text) ->
    (((text.replace /&/g, "&amp;").replace /</g, "&lt;").replace />/g, "&gt;").replace /"/g, "&quot;"

dump = (req) ->
    util.log "#{req.url.replace('/api/', '$')}: #{JSON.stringify req.body}"

norm_id = (id, secret, can_be_home) ->
    # if secret's empty, but substituting for home's allowed
    id = onliners[secret].aliases["home"] if (not id? or id is "") and can_be_home and onliners[secret]

    # if secret is valid
    if onliners[secret] and id in Object.keys onliners[secret].aliases
            id = onliners[secret].aliases[id]

    throw message: "missing object id" if not id?
    throw message: "invalid object id" if (isNaN parseInt id) or ((parseInt id) != (parseFloat id))
    throw message: "object id out of range" if not (map.low <= id <= map.high)

    parseInt id

withdraw = (m, f, w, d, g, ppl, i, j) ->
    # check
    params = map.map[i][j][2]
    ppl_qty = params.ppl[params.owner] or 0

    if params.m < m
        throw message: "not enough money: need #{m}, have #{params.m}"
    if params.f < f
        throw message: "not enough fuel: need #{f}, have #{params.f}"
    if params.w < w
        throw message: "not enough wood: need #{w}, have #{params.w}"
    if params.d < d
        throw message: "not enough diamonds: need #{d}, have #{params.d}"
    if params.g < g
        throw message: "not enough grain: need #{g}, have #{params.g}"
    if ppl and ppl_qty < ppl
        throw message: "not enough ppl: need #{ppl}, have #{ppl_qty}"

    # withdraw
    map.map[i][j][2].m -= m
    map.map[i][j][2].f -= f
    map.map[i][j][2].w -= w
    map.map[i][j][2].d -= d
    map.map[i][j][2].g -= g
    map.map[i][j][2].ppl[params.owner] = ppl_qty - ppl
    map.map[i][j][2].all -= ppl

withdraw_part = (i, j, ppl) ->
    return if ppl == 0

    A = map.map[i][j][2].ppl
    K = (Object.keys A).sort (a, b) -> A[a] - A[b]
    remain = ppl
    
    for k, x in K
        d = Math.max 0, Math.round remain / (K.length - x)
        
        A[k] -= d
        remain -= d

    map.map[i][j][2].all -= ppl

min_troop_size = (m, f, w, d, g, lvl) ->
    k = Math.pow 2, (Math.floor lvl / 3)
    Math.ceil Math.max m/5/k, f/5/k, w/1/k, d*200/k, g/10/k

calculate_fuel = (i1, i2, lvl, ppl, attack) ->
    return 0 if ppl == 0
    f = ppl * (i1 - i2)*(i1 - i2) / (25 * Math.pow 2, Math.floor lvl / 3)
    if attack
        f *= 2.5
    else
        f *= Math.max 0.5, 1 - 0.1 * (Math.log ppl) / Math.LN10
    t1 = map.biomes[i1] == _.SWAMP
    t2 = map.biomes[i2] == _.SWAMP
    return (Math.ceil 0.75 * f) if t1 and t2
    return (Math.ceil 1.25 * f) if t1
    return (Math.ceil 1.75 * f) if t2
    return (Math.ceil f)

find_interchanges = ([i1, j1], [i2, j2], login) ->
    interchanges = []

    # way 1: take into account all buildings on the map
    ###
        s1 = s2 = 0
        $.each map.map, (cluster, I) ->
            for [biome, obj, params], J in cluster
                if obj in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM] and is_owner params.owner, login
                    if (parseInt I) == i1 and J == j1
                        s1 = interchanges.length
                    if (parseInt I) == i2 and J == j2
                        s2 = interchanges.length
                    interchanges.push [(parseInt I), J]
        return [interchanges, s1, s2]
    ###

    # way 2: take into account only buildings between A and B 
    if i1 < i2
        sgn = +1
    else if i1 > i2
        sgn = -1
    else if j1 < j2
        sgn = +1
    else if j1 > j2
        sgn = -1
    else
        return []
    
    [I, J] = [i1, j1]
    while I != i2 or J != j2
        interchanges.push [I, J] if map.map[I][J][1] in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM] and \
                                    is_owner map.map[I][J][2].owner, login
        J += sgn
        if J == -1
            I -= 1
            J = map.s - 1
        if J == map.s
            I += 1
            J = 0

    interchanges.push [i2, j2]
    return [interchanges, 0, interchanges.length - 1]

can_pass = (i1, i2, j1, ppl) ->
    f_need = calculate_fuel i1, i2, map.map[i1][j1][2].lvl, ppl
    if f_need <= map.map[i1][j1][2].f then f_need else -1

build_route = (interchanges, s1, s2, ppl) ->
    n = interchanges.length - 1
    # build list of connectible vertices (=cities with enough fuel)
    g = []
    for [i1, j1], X1 in interchanges
        g.push []
        for X2 in [X1+1..n]
            break if X2 > n
            i2 = interchanges[X2][0]
            if (f_need = can_pass i1, i2, j1, ppl) != -1
                g[X1].push [X2, f_need]
    # run Dijkstra's algorithm on the graph produced above
    INF = 1e15
    [d, u, p] = [[], [], []]
    for X in [0..n]
        d.push INF
        u.push false
        p.push 0
    d[s1] = 0
    for I in [0..n]
        V = -1
        for J in [0..n]
            if not u[J] and (V == -1 or d[J] < d[V])
                V = J
        if d[V] == INF
            break
        u[V] = true

        for [to, len] in g[V]
            if d[V] + len < d[to]
                d[to] = d[V] + len
                p[to] = V
    # build the route and return it
    route = [interchanges[s2]]
    cur = s2
    while cur != s1
        cur = p[cur]
        route.splice 0, 0, interchanges[cur]
    route

route_cost = (route, ppl, check) ->
    f_saved = [0]
    for x in [0..route.length-2]
        [i1, j1] = route[x]
        [i2, j2] = route[x+1]
        id       = map.s*i1+j1-map.s/2+1
        f_need   = calculate_fuel i1, i2, map.map[i1][j1][2].lvl, ppl
        f_saved[0] += f_need
        node = {}
        node[id] = f_need
        if check
            f_have = map.map[i1][j1][2].f
            throw message: "#{id}: not enough fuel: need #{f_need}, have #{f_have}" if f_have < f_need
        f_saved.push node
    f_saved

object_price = (what, i1, j1, i2, secret) ->
    login = if secret then onliners[secret].login else map.map[i1][j1][2].owner

    switch what
        when "tower"
            m = 500
            w = 100
            d = 1
        when "castle"
            # how many castles this very gentleman already has?
            castles = 0

            $.each map.map, (cluster, i) ->
                for [biome, obj, params] in cluster
                    if obj == _.CASTLE and params.owner == login
                        castles++

            m = Math.floor 2500 * (Math.pow 3/2, castles - 1)
            w = Math.floor  500 * (Math.pow 3/2, castles - 1)
            d = 3 * castles
        when "market", "forum"
            # how many markets of this lad are known?
            markets = 0

            $.each map.map, (cluster, i) ->
                for [biome, obj, params] in cluster
                    if obj in [_.MARKET, _.FORUM] and params.owner == login
                        markets++

            m = Math.floor 25000 * (Math.pow 3/2, markets)
            w = Math.floor  5000 * (Math.pow 3/2, markets)
            d = 25 + 5 * markets
        else
            throw message: "invalid building type"

    if i1? and j1? and i2?
        lvl = map.map[i1][j1][2].lvl

        ppl = min_troop_size m, 0, w, d, 0, lvl
        f = calculate_fuel i1, i2, lvl, ppl
    else
        ppl = f = undefined

    [m, w, d, f, ppl]

where_to_flee = (i, j, login) ->
    walk = (I, J, x) ->
        while true
            J += x
            if J == -1
                I -= 1
                J = map.s - 1
            if J == map.s
                I += 1
                J = 0
            return [9999] if (Math.abs 2*I) > map.k
            return [I, J] if map.map[I][J][1] in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM] and \
                             map.map[I][J][2].owner == login

    [il, jl] = walk i, j, -1
    [ir, jr] = walk i, j, +1

    if (Math.abs i - il) < (Math.abs i - ir) then [il, jl] else [ir, jr]

calculate_can_flee = (i1, i2, f, lvl) ->
    Math.round f * (25 * Math.pow 2, Math.floor lvl / 3) / ((i1 - i2)*(i1 - i2))

[i0, j0] = map.F 0
xchg_max_portion =
    m: 5000
    f: 5000
    w: 1000
    d: 5

xchg_rate = (x, y) ->
    cx = map.map[i0][j0][2][x]
    cy = map.map[i0][j0][2][y]
    delta = cx/(cx - xchg_max_portion[x])
    cy / cx / delta

intersect = (i1, j1, i2, j2) ->
    for c in map.map[i1][j1][2].cliques
        return true if c in map.map[i2][j2][2].cliques
    false

is_clique_admin = (i, j) ->
    flag = false

    $.each map.cliques, (v) ->
        flag = v[0] == i && v[1] == x
        return if flag

    flag

is_owner = (owner, login) ->
    return false unless owner
    clique = map.cliques[owner] or [i0, j0]
    map.map[clique[0]][clique[1]][2].owner == login or owner == login

code_chars = ["zu", "ra", "bi", "na", "sho", "tu", "fe", "mu", "hi", "pa", "lu", "di", "de", "zo", "be", "cock"]
encode_code = (code) ->
    (code_chars[parseInt char, 16] for char in code).join ""

decode_code = (code) ->
    out = ""
    i = 0
    while i < code.length
        for char, k in code_chars
            if (code.substr i, char.length) == char
                i += char.length
                out += k.toString 16
                break
    out

is_dishonest_bot = (login) -> login[0] != "$" and not log.is_client login
no_dishonest_bots = (res) -> res.send 403, "no, you can't do that"

is_bot = (login) -> login[0] == "$"
no_bots = (res) -> res.send 403, error "method not allowed in Bots API"

backup = () ->
    buffer = BSON.serialize onliners: onliners, days: days, mines_check: mines_check
    fs.writeFileSync "backup/server.bson", buffer
    util.log "server info backed up to backup/server.bson"


# let's read previous backup, if present
if fs.existsSync "backup/server.bson"
    util.log "recovered from termination"
    buffer = fs.readFileSync "backup/server.bson"
    fs.unlinkSync "backup/server.bson"
    {onliners, days, mines_check} = BSON.parse buffer

# let's establish emergency onliners and map backup
terminate = () ->
    util.log "REQUESTED PROCESS TERMINATION"
    backup()
    map.backup()
    process.exit 1

process.on "SIGINT",  terminate
process.on "SIGTERM", terminate

# load bots from database
db.all "SELECT * FROM bots", (err, rows) ->
    rows.forEach (row) ->
        onliners[row.secret] =
            when:    0
            login:   row.login
            owner:   row.owner
            aliases: { home: row.home }

app = express()

app.use body_parser.urlencoded extended: true
app.use logger "dev"
app.use "/", gzippo.staticGzip "#{__dirname}/../static"
app.use (err, req, res, next) ->
    console.error "Express error: #{err.stack}"
    res.send 500, "something went wrong"

# users and bots
app.post "/api/register", (req, res) ->
    dump req
    ###
        POST ->
            | String email
            | String login
            | String password
    ###
    {email, login, password} = req.body

    email = email.trim() if is_str email
    login = login.trim() if is_str login

    return res.send error "email not specified" if not email
    
    return res.send error "password not specified" if not password

    password = password.toString()

    # check login – it must consist only of latin letters and numbers
    # and be at least 4 and no more than 32 symbols long
    return res.send error "invalid login" if not login_regexp.test login

    # check if user already exists
    db.get "SELECT * FROM users WHERE login=? OR email=?", [login, email], (err, row) ->
        return res.send error "user already exists" if row

        ts = timestamp()
        # create a new row in "users" db
        new_user = [
            email,           # email
            login,           # login
            (hash password), # password
            -ts,             # last_login
            0                # home
        ]
        db.run "INSERT INTO users (email, login, password, last_login, home) VALUES (?, ?, ?, ?, ?)", new_user, () ->
            code = encode_code trimmed_hash login + ts
            # done
            mail.send email, login, code
            res.send ok "welcome aboard"

app.get "/confirm/:code", (req, res) ->
    code = decode_code req.params.code
    flag = true

    db.all "SELECT login, -last_login AS ts FROM users WHERE last_login < 0", (err, rows) ->
        return if err
        rows.forEach (row) ->
            kod = trimmed_hash row.login + row.ts
            if code == kod
                # confirmation complete
                flag = false
                ts = timestamp()
                db.run "UPDATE users SET last_login = ? WHERE login = ?", [-ts, row.login], () ->
                    secret = trimmed_hash row.login + ts
                    res.redirect "/game/##{row.login};#{secret}"
        res.send "error" if flag

# users and bots
app.post "/api/login", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | String _default / login
            | String password
    ###
    [login, password] = [req.body._default or req.body.login, req.body.password]

    # first of all, let's check if user is already logged in
    prev_secret = req.body.secret
    if onliners[prev_secret] and onliners[prev_secret].login == login
        ts = timestamp()
        db.run "UPDATE users SET last_login = ? WHERE login = ?", [ts, login], () ->
            secret = trimmed_hash login + ts
            onliners[secret] = $.extend {}, onliners[prev_secret]

            delete onliners[prev_secret]
        
            admin = []
            $.each map.cliques, ([i, j], k) ->
                if map.map[i][j][2].owner == login
                   admin.push k

            set_time secret
            res.send ok { secret: secret, admin: admin }
    else
        # check the presence of all necessary params
        return res.send error "incomplete information" if not (is_str login) or not (is_str password)

        login = login.trim()
        db.get "SELECT * FROM users WHERE login = ?", login, (err, row) ->
            # check if there is a user with such login
            return res.send error "incorrect login" if not row

            if prev_secret and prev_secret[0] == "-" and (prev_secret.substr 1) == trimmed_hash login + -row.last_login
                first_time = true
            else
                # check if password matches
                return res.send error "incorrect password" if (hash password) != row.password

                first_time = false

            # identity confirmed
            ts = timestamp()
            db.run "UPDATE users SET last_login = ? WHERE login = ?", [ts, login], () ->
                secret = trimmed_hash login + ts

                onliners[secret] =
                    when:    0
                    login:   login
                    aliases: {}

                if first_time
                    db.get "SELECT COUNT(*) AS cnt FROM users WHERE last_login > 0", (err, row) ->

                        N = row.cnt
                        pos = 0
                        [i, j] = [0, 0]

                        while true
                            sgn = if Math.random() - 0.5 < 0 then -1 else 1
                            pos = sgn * Math.floor 8*(Math.random()*(N - (Math.pow N, 0.95) + 1) + Math.pow N, 0.95)
                            pos = (Math.floor Math.random()*(map.high - map.low + 1)) + map.low \
                                   unless map.low <= pos <= map.high
                            [i, j] = map.F pos
                            break if map.map[i][j][1] == _.VOID

                        x = 1.5 if 101 <= N <= 500
                        x = 1.0 if N > 500

                        # let's give a fellow a castle and a pile of money & wood & fuel
                        map.map[i][j][1] = _.CASTLE
                        map.map[i][j][2] =
                            params =
                                name: "Newcastle"
                                owner: login
                                cliques: []
                                ppl: {}
                                all: 100
                                lvl: 1
                                mf: 1
                                ff: 1
                                m: 2000*x
                                f: 2000*x
                                w: 200 *x
                                d: 2   *x
                                g: 3000*x

                        map.map[i][j][2].ppl[login] = 100 # stupid & implicit JS syntax!

                        db.run "UPDATE users SET home = ? WHERE login = ?", [pos, login], () ->
                            db.run "INSERT INTO log (time, subject, event) VALUES (DATETIME(), ?, 'reg')", login, () -> log.notify()
                            onliners[secret].aliases["home"] = onliners[secret].aliases["Newcastle"] = pos
                            set_time secret
                            res.send ok { secret: secret, admin: [], n: N }
                else
                    # make aliases for all towers, castles and markets
                    aliases = {}
                    admin = []
                    $.each map.map, (cluster, i) ->
                        for obj, j in cluster
                            if obj[2].owner == login
                                aliases[obj[2].name] = map.s*i + j - map.s/2 + 1
                    $.each map.cliques, ([i, j], k) ->
                        if map.map[i][j][2].owner == login
                           admin.push k
                    aliases["home"] = row.home
                    onliners[secret].aliases = aliases
                    set_time secret
                    res.send ok { secret: secret, admin: admin }

# users and bots
app.post "/api/logout", (req, res) ->
    dump req

    secret = req.body.secret

    # check if user were logged in
    return res.send error "not logged in" if not onliners[secret] or onliners[secret].login[0] == "$"

    # remove user from onliners
    delete onliners[secret]

    res.send ok()

# users and bots
app.post "/api/show", (req, res) ->
    dump req
    ###
        POST ->
            | ID    id / _default
    ###
    id = req.body.id or req.body._default
    secret = req.body.secret

    if onliners[secret]
        login = onliners[secret].login

    try
        id = norm_id id, secret, true
        [i, j] = map.F id
    catch err
        return res.send error err.message

    result = []
    for [biome, obj, params] in map.map[i]
        switch obj
            when _.TREE, _.MINE
                ppl = all: params.all

                if onliners[secret]
                    ppl.thy = 0
                    ppl.thy += z for [x, y, z] in params.ppl when x == login

                result.push [biome, obj, qty: params.qty, ppl: ppl]
            else
                new_params = $.extend {}, params
                if params.ppl
                    ppl = all: params.all
                    ppl.thy = params.ppl[login] or 0 if onliners[secret]
                    new_params.ppl = ppl
                    new_params.all = undefined
                new_params.m = new_params.f = new_params.w = new_params.d = new_params.g = undefined
                new_params.cliques = undefined
                new_params.offers = undefined
                if params.cliques and params.owner in params.cliques
                    new_params.shared = true
                result.push [biome, obj, new_params]

    res.send ok cluster: i, biome: map.biomes[i], objects: result

# users and bots
app.post "/api/info", (req, res) ->
    dump req
    ###
        POST ->
            | ID        id / _default
            | Anything  scout
    ###
    id = req.body.id or req.body._default
    secret = req.body.secret

    try
        id = norm_id id, secret, true
        [i, j] = map.F id
    catch err
        return res.send error err.message

    [biome, obj, params] = map.map[i][j]

    new_params = $.extend {}, params

    if onliners[secret]
        [ih, jh] = map.F onliners[secret].aliases["home"]
        if req.body.scout
            try
                withdraw 1000, 0, 0, 0, 0, 0, ih, jh
                flag = true
            catch err
                return res.send error err.message
        else
            flag = is_owner new_params.owner, onliners[secret].login
    else
        flag = false

    if new_params.ppl
        $.each new_params.ppl, (v, k) ->
            new_params.ppl[k] = undefined if v == 0

    if obj in [_.TOWER, _.CASTLE] and not (i == i0 and j == j0) and not flag
        new_params.m = new_params.f = new_params.w = new_params.d = new_params.g = undefined

    res.send ok id: id, cluster: i, object: [biome, obj, new_params]

# users and bots
app.all "/api/users", (req, res) ->
    dump req

    db.get "SELECT COUNT(*) AS cnt FROM users WHERE last_login > 0", (err, row) ->
        if req.query.src == "wiki"
            res.send (row.cnt + 1).toString()
        else
            res.send ok all: row.cnt, online: log.get_users()

# users and bots
app.all "/api/days", (req, res) ->
    dump req

    res.send ok qty: days

# users and bots
app.all "/api/bots", (req, res) ->
    dump req

    db.get "SELECT COUNT(*) AS cnt FROM bots", (err, row) ->
        secret = req.body.secret
        if onliners[secret]
            db.all "SELECT login, secret FROM bots WHERE owner = ?", onliners[secret].login, (err, rows) ->
                thy = []
                rows.forEach (row) ->
                    thy.push [row.login, row.secret]
                res.send ok ppl: row.cnt, thy: thy
        else
            res.send ok ppl: row.cnt

# users and bots
app.post "/api/aliases", (req, res) ->
    dump req

    secret = req.body.secret

    return res.send error "not logged in" if not onliners[secret]
   
    return no_dishonest_bots res if is_dishonest_bot onliners[secret].login

    return res.send ok onliners[secret].aliases

# users and bots
app.post "/api/rename", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID     id
            | String _default / name
    ###
    [secret, id, name] = [req.body.secret, req.body.id, req.body.name or req.body._default]

    # check secret
    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login
   
    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        id = onliners[secret].aliases["home"]
        [i, j] = map.F id
    else
        try
            id = norm_id id, secret, true
            [i, j] = map.F id
        catch err
            return res.send error err.message
        
        # check object's owner
        return res.send error "object is not yours" if not (is_owner map.map[i][j][2].owner, onliners[secret].login)
    
    # check object's type
    return res.send error "object is not a building" if map.map[i][j][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]

    # check the presence of 'name' param
    return res.send error "name not specified" if not (is_str name)

    name = sanitize name

    # check new name's uniqueness
    return res.send error "already used name" if onliners[secret].aliases[name]

    first_time = map.map[i][j][2].name == "Newcastle"

    # withdraw one diamond if it's not the first renaming
    try
        withdraw 0, 0, 0, 1, 0, 0, i, j unless first_time
    catch err
        return res.send error err.message

    # remove previous alias
    delete onliners[secret].aliases[map.map[i][j][2].name]

    # and create a new one
    onliners[secret].aliases[name] = id

    # and, finally, rename the object
    map.map[i][j][2].name = name
    set_time secret
    res.send ok ($dec: { d: 1 } unless first_time)

# users only
app.post "/api/build", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | String what
            | ID     from
            | ID     where / to
            | String name
    ###
    [secret, what, from, where, name] = [req.body.secret, req.body.what, req.body.from, req.body.where or req.body.to, req.body.name]

    # check secret
    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    return no_bots res if is_bot login

    # check both 'from' and 'where' fields
    try
        from = norm_id from, secret, true
        [i1, j1] = map.F from
    catch err
        return res.send error "from: #{err.message}"

    try
        where = norm_id where, secret, false
        [i2, j2] = map.F where
    catch err
        return res.send error "where: #{err.message}"

    # check if 'from' is either tower or castle, belonging to player
    return res.send error "'from' object is not yours" if not (is_owner map.map[i1][j1][2].owner, login)

    # check availability at 'where' place
    return res.send error "##{where} already taken" if map.map[i2][j2][1] != _.VOID

    # check building type
    return res.send error "invalid building type" if not (is_str what)

    # check name
    return res.send error "name not specified" if not (is_str name)
    
    name = sanitize name

    # check new name's uniqueness
    return res.send error "already used name" if onliners[secret].aliases[name]
    
    # check availability of resources and labour force at 'from'
    what = what.trim().toLowerCase()
    switch what
        when "tower"
            obj = _.TOWER
            params =
                name: name
                owner: login
                cliques: []
                ppl: {}
                all: 0
                lvl: 1
                m: 0
                f: 0
                w: 0
                d: 0
                g: 0
        when "castle"
            obj = _.CASTLE
            params =
                name: name
                owner: login
                cliques: []
                ppl: {}
                all: 0
                lvl: 1
                mf: 1
                ff: 1
                m: 500
                f: 500
                w: 0
                d: 0
                g: 0
        when "market"
            obj = _.MARKET
            params =
                name: name
                owner: login
                cliques: []
                ppl: {}
                all: 0
                lvl: 9
                tax: 0.25
                offers: []
                m: 0
                f: 0
                w: 0
                d: 0
                g: 0
        else
            return res.send error "invalid building type"

    # let's calculate all them costs for the building
    [m, w, d, f, ppl] = object_price what, i1, j1, i2

    return res.send error "not enough ppl: need #{ppl}, have #{map.map[i1][j1][2].all}" \
           if map.map[i1][j1][2].all < ppl

    # before we go, withdraw all needed resources
    try
        withdraw m, f, w, d, 0, 0, i1, j1
        withdraw_part i1, j1, ppl if what != "market"
    catch err
        return res.send error err.message

    # finally, let's erect the building!
    params.ppl[login] = 0
    if what != "market"
        params.ppl[login] = ppl
        params.all = ppl
        switch what
            when "tower"
                params.g = ppl
            when "castle"
                params.g = ppl * 3
    map.map[i2][j2][1] = obj
    map.map[i2][j2][2] = params

    # add it to aliases
    onliners[secret].aliases[params.name] = where

    # save the record in log
    db.run "INSERT INTO log (time, subject, event) VALUES (DATETIME(), ?, 'build|#{where}')", login, () -> log.notify()
    # and inform client that everything's ok
    set_time secret
    res.send ok [
                    {id: from,  $dec: { m: m, f: f, w: w, d: d, ppl: params.ppl[login] } },
                    {id: where, $set: { what: what, name: params.name, owner: login, ppl: params.ppl[login] } }
                ]

# users and bots
app.post "/api/attack_cost", (req, res) ->
    dump req
    ###
        POST ->
            | ID    from
            | ID    where / to
            | Int   ppl
    ###
    [secret, from, where, ppl] = [req.body.secret, req.body.from, req.body.where or req.body.to, req.body.ppl]

    try
        from = norm_id from, secret, true
        [i1, j1] = map.F from
    catch err
        return res.send error "from: #{err.message}"

    return res.send error "'from' object is neither tower nor castle" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE]

    try
        [i2, j2] = map.F (norm_id where, secret, false)
    catch err
        return res.send error "where: #{err.message}"

    return res.send error "'where' object cannot be attacked" if map.map[i2][j2][1] not in [_.TOWER, _.CASTLE, _.FARM]

    return res.send error "invalid ppl" if not (is_qty ppl)

    f = calculate_fuel i1, i2, map.map[i1][j1][2].lvl, ppl, true

    res.send ok f: f

# users and bots
app.post "/api/build_cost", (req, res) ->
    dump req
    ###
        POST ->
            | String what / _default
            | ID     where / to
            | ID     from
    ###
    [secret, what, where, from] = [req.body.secret, req.body.what or req.body._default, req.body.where or req.body.to, req.body.from]
   
    return res.send error "invalid building type" if not (is_str what)

    what = what.trim().toLowerCase()
    if what in ["tower", "castle", "market"]
        if where?
            try
                from = norm_id from, secret, true
                [i1, j1] = map.F from
            catch err
                return res.send error "from: #{err.message}"

            return res.send error "'from' object is not a building" \
                   if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]

            try
                where = norm_id where, secret, false
                [i2, j2] = map.F where
            catch err
                return res.send error "where: #{err.message}"

            return res.send error "##{where} already taken" if map.map[i2][j2][1] != _.VOID

            [m, w, d, f, ppl] = object_price what, i1, j1, i2
        else
            return res.send error "not logged in" if what in ["castle", "market"] and not onliners[secret]

            [m, w, d, f, ppl] = object_price what, undefined, undefined, undefined, secret

        res.send ok m: m, f: f, w: w, d: d, ppl: ppl
    else
        res.send error "invalid building type"

# users only
app.post "/api/attack", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        FROM ->
            | ID    from
            | ID    where / to
            | Int   ppl
    ###
    [secret, from, where, ppl] = [req.body.secret, req.body.from, req.body.where or req.body.to, req.body.ppl]

    return res.send error "not logged in" if not onliners[secret]
        
    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    return no_bots res if is_bot login
 
    try
        from = norm_id from, secret, true
        [i1, j1] = map.F from
    catch err
        return res.send error "from: #{err.message}"

    return res.send error "'from' object is neither tower nor castle" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE]
    
    return res.send error "'from' object is not yours" if not (is_owner map.map[i1][j1][2].owner, login)

    try
        where = norm_id where, secret, false
        [i2, j2] = map.F where
    catch err
        return res.send error "where: #{err.message}"

    what = map.map[i2][j2][1]
    return res.send error "'where' object cannot be attacked" if what not in [_.TOWER, _.CASTLE, _.FARM]

    login2 = map.map[i2][j2][2].owner

    return res.send error "invalid ppl" if not (is_qty ppl)

    ppl = parseInt ppl

    return res.send error "not enough ppl: need #{ppl}, have #{map.map[i1][j1][2].all}" \
           if map.map[i1][j1][2].all < ppl

    # if attacking a farm
    if what == _.FARM
        j3 = undefined
        d = 1e15
        
        for [biome, obj, params], j in map.map[i2]
            if obj in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM] and params.owner == login2 and (d3 = Math.abs j - j2) < d
                d = d3
                j3 = j
 
        if j3?
            lvl3 = map.map[i2][j3][2].lvl
        else
            lvl3 = 1

    [lvl1, lvl2] = [map.map[i1][j1][2].lvl, if what == _.FARM then lvl3 else map.map[i2][j2][2].lvl]
    return res.send error "target lvl must within 2 of your lvl" if (Math.abs lvl1 - lvl2) > 2

    db.get "SELECT (JULIANDAY() - JULIANDAY(time)) AS diff FROM log WHERE subject=? AND event='reg'", login2, (err, row) ->
        if row.diff < 3
            ago = Math.floor row.diff*24
            return res.send error "#{login2} was registered #{ago} hours ago, wait another #{72 - ago} hours"

        # calculate needed fuel
        f = calculate_fuel i1, i2, lvl1, ppl, true

        try
            withdraw 0, f, 0, 0, 0, 0, i1, j1
        catch err
            return res.send error err.message

        # now everything is ready for a good punch-up!
        attacker_force = (Math.random()*0.4 + 0.8) * ppl * (Math.floor (lvl1 + 1) / 2)
        defender_level = (Math.floor lvl2 / 2 + 1)
        defender_force = map.map[i2][j2][2].all * (Math.random()*0.4 + 0.8) * defender_level
        
        # now when all forces gathered together, let's smash them!
        if attacker_force <= defender_force
            # defenders win
            # let's decrease respective defenders count in a quarter of dead attackers
            # like their deaths was not for nothing
            defender_loss = Math.round attacker_force/defender_level * 0.25
            withdraw_part i1, j1, ppl
            if what == _.FARM
                map.map[i2][j2][2].all -= defender_loss
            else
                withdraw_part i2, j2, defender_loss

            event = "defeat|#{from}|#{where}|#{ppl}|#{defender_loss}"
            db.run "INSERT INTO log (time, subject, object, event) VALUES (DATETIME(), ?, ?, ?)", [login, login2, event], () -> log.notify()
            set_time secret
            res.send defeat [
                                { id: from,  $dec: { ppl: ppl, f: f } },
                                { id: where, $dec: { ppl: defender_loss } }
                            ]
        else
            # attackers win
            # which means that 1/4..1/2 of defenders are slaughtered, and the remains flee to the nearest building
            not_luck   = Math.random() * 0.25 + 0.25
            def_dead   = Math.round map.map[i2][j2][2].all * not_luck
            if what == _.FARM
                map.map[i2][j2][2].all -= def_dead
            else
                withdraw_part i2, j2, def_dead
            def_remain = Math.round map.map[i2][j2][2].all
            att_remain = Math.min ppl, (Math.floor (attacker_force - defender_force) / defender_level)
            # firstly, attackers loot whatever they can
            k = Math.pow 2, (Math.floor lvl1 / 3)
            not_luck = 1 if map.map[i2][j2][1] == _.TOWER
            # then awarded heroes come home with all their possessions
            withdraw_part i1, j1, ppl - att_remain
            if what == _.FARM
                m_loot = f_loot = w_loot = d_loot = 0
                g_loot = Math.floor not_luck * Math.min map.map[i2][j2][2].qty, att_remain*10*k
            else
                m_loot = Math.floor not_luck * Math.min map.map[i2][j2][2].m, att_remain*5*k
                f_loot = Math.floor not_luck * Math.min map.map[i2][j2][2].f, att_remain*5*k
                w_loot = Math.floor not_luck * Math.min map.map[i2][j2][2].w, att_remain*1*k
                d_loot = Math.floor not_luck * Math.min map.map[i2][j2][2].d, Math.floor att_remain/200*k
                g_loot = 0
            withdraw -m_loot, -f_loot, -w_loot, -d_loot, -g_loot, 0, i1, j1
            withdraw  m_loot,  f_loot,  w_loot,  d_loot,  g_loot, 0, i2, j2
            flee_msg = undefined
            can_flee = m_flee = w_flee = d_flee = 0
            if what in [_.TOWER, _.FARM]
                if what == _.TOWER and map.map[i2][j2][2].owner not in map.map[i2][j2][2].cliques
                    # finally, remaining defenders flee
                    [iF, jF] = where_to_flee i2, j2, login2
                    if iF?
                        if iF == i2
                            can_flee = def_remain
                        else
                            can_flee = Math.min def_remain, calculate_can_flee i2, iF, map.map[i2][j2][2].f, lvl2
                        k_flee = Math.pow 2, (Math.floor lvl2 / 3)
                        m_flee = Math.min map.map[i2][j2][2].m, can_flee*5*k_flee
                        w_flee = Math.min map.map[i2][j2][2].w, can_flee*1*k_flee
                        d_flee = Math.min map.map[i2][j2][2].d, Math.floor can_flee/200*k_flee
                        withdraw -m_flee, 0, -w_flee, -d_flee, 0, -can_flee, iF, jF
                        flee_msg = { id: map.s*iF + jF - map.s/2 + 1, $inc: { ppl: can_flee, m: m_flee, w: w_flee, d: d_flee } }
                # and now, when no one's left, tower or farm has to cease to exist
                map.map[i2][j2][1] = _.VOID
                map.map[i2][j2][2] = {}
                # take care of aliases
                $.each onliners, (V) ->
                    $.each V.aliases, (v, k) ->
                        delete V.aliases[k] if v == where
            
            # let's notify everyone
            event = "victory|#{from}|#{where}|#{ppl-att_remain}|#{def_dead}|#{m_loot}|#{f_loot}|#{w_loot}|#{d_loot}|#{g_loot}"
            db.run "INSERT INTO log (time, subject, object, event) VALUES (DATETIME(), ?, ?, ?)", [login, login2, event], () -> log.notify()
            u = undefined
            msg = [
                      { id: from,  $dec: { ppl: ppl, f: f }, $inc: { ppl: att_remain, m: m_loot or u, f: f_loot or u, w: w_loot or u, d: d_loot or u, g: g_loot or u} },
                      { id: where, $dec: { ppl: def_dead + can_flee, m: (m_loot + m_flee) or u, f: f_loot or u, w: (w_loot + w_flee) or u, d: (d_loot + d_flee) or u, g: g_loot or u } }
                  ]
            msg.push flee_msg if flee_msg
            set_time secret
            res.send victory msg

# users and bots
app.post "/api/hire", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID    id
            | Int   ppl / _default
    ###
    [secret, id, ppl] = [req.body.secret, req.body.id, req.body.ppl or req.body._default]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        id = onliners[secret].aliases["home"]
        [i, j] = map.F id
    else
        try
            id = norm_id id, secret, true
            [i, j] = map.F id
        catch err
            return res.send error err.message

        return res.send error "object is not a building" if map.map[i][j][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]

        return res.send error "object is not yours" if not (is_owner map.map[i][j][2].owner, login)

    return res.send error "invalid ppl" if not (is_qty ppl)

    ppl = parseInt ppl

    # 1 fully-trained and equipped employee and soldier = 1m,
    # LIMITED OFFER!!!
    try
        withdraw ppl, 0, 0, 0, 0, 0, i, j
        map.map[i][j][2].ppl[login] = (map.map[i][j][2].ppl[login] or 0) + ppl
        map.map[i][j][2].all += ppl
    catch err
        return res.send error err.message

    set_time secret
    res.send ok { id: id, $dec: { m: ppl }, $inc: { ppl: ppl } }

# users and bots
app.post "/api/burn", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID    id
            | Int   w / _default
    ###
    [secret, id, w] = [req.body.secret, req.body.id, req.body.w or req.body._default]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        id = onliners[secret].aliases["home"]
        [i, j] = map.F id
    else
        try
            id = norm_id id, secret, true
            [i, j] = map.F id
        catch err
            return res.send error err.message

        return res.send error "object is not a building" if map.map[i][j][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
        
        return res.send error "object is not yours" if not (is_owner map.map[i][j][2].owner, login)

    return res.send error "invalid w" if not (is_qty w)

    w = parseInt w

    try
        withdraw 0, -2 * w, w, 0, 0, 0, i, j
    catch err
        return res.send error err.message

    set_time secret
    res.send ok { id: id, $dec: { w: w }, $inc: { f: 2 * w } }

# users only
app.post "/api/move", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID    from
            | ID    where / to
            | Int   ppl
    ###
    [secret, from, where, ppl] = [req.body.secret, req.body.from, req.body.where or req.body.to, req.body.ppl]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    return no_bots res if is_bot login

    return res.send error "invalid ppl" if not (is_qty ppl)

    ppl = parseInt ppl

    try
        from = norm_id from, secret, true
        [i1, j1] = map.F from
    catch err
        return res.send error "from: #{err.message}"

    return res.send error "'from' object is not a building" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
    
    return res.send error "'from' object must be either yours or a shared building from one of your cliques" \
           if not map.map[i1][j1][2].cliques or (map.map[i1][j1][2].owner not in map.map[i1][j1][2].cliques.concat login)

    try
        where = norm_id where, secret, false
        [i2, j2] = map.F where
    catch err
        return res.send error "where: #{err.message}"

    return res.send error "'where' object is not a building" if map.map[i2][j2][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
    
    return res.send error "'where' object must be either yours or a shared building from one of your cliques" \
           if map.map[i2][j2][2].owner not in map.map[i1][j1][2].cliques.concat login

    lvl    = map.map[i1][j1][2].lvl
    f_need = calculate_fuel i1, i2, lvl, ppl

    return res.send error "not enough ppl: need #{ppl}, have #{map.map[i1][j1][2].ppl[login] or 0}" \
           if not map.map[i1][j1][2].ppl[login]? or map.map[i1][j1][2].ppl[login] < ppl

    return res.send error "not enough fuel: need #{f_need}, have #{map.map[i1][j1][2].f}" \
           if map.map[i1][j1][2].f < f_need

    # take warriors from this building
    map.map[i1][j1][2].f -= f_need
    map.map[i1][j1][2].ppl[login] -= ppl
    map.map[i1][j1][2].all -= ppl

    # and move 'em to that building
    map.map[i2][j2][2].ppl[login] = (map.map[i2][j2][2].ppl[login] or 0) + ppl
    map.map[i2][j2][2].all += ppl

    set_time secret
    res.send ok [
                    {id: from,  $dec: { f: f_need, ppl: ppl } },
                    {id: where, $inc: { ppl: ppl } }
                ]

# users and bots
app.post "/api/transfer", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID        from
            | ID        where / to
            | Anything  optimize
            | Int       m
            | Int       f
            | Int       w
            | Int       d
            | Int       g
            | Int       ppl
    ###
    [secret, from, where] = [req.body.secret, req.body.from, req.body.where or req.body.to]
    {m, f, w, d, g, ppl, optimize} = req.body
    [m, f, w, d, g, ppl] = [(parseInt m or 0), (parseInt f or 0), (parseInt w or 0), (parseInt d or 0), (parseInt g or 0), (parseInt ppl or 0)]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return res.send error "invalid money" if not (is_qty m)
    return res.send error "invalid fuel" if not (is_qty f)
    return res.send error "invalid wood" if not (is_qty w)
    return res.send error "invalid diamonds" if not (is_qty d)
    return res.send error "invalid grain" if not (is_qty g)
    return res.send error "invalid ppl" if not (is_qty ppl)

    return res.send error "nothing is transferred" if m + f + w + d + g + ppl == 0

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        from = onliners[secret].aliases["home"]
        [i1, j1] = map.F from
        owner = onliners[secret].owner
    else
        try
            from = norm_id from, secret, true
            [i1, j1] = map.F from
        catch err
            return res.send error "from: #{err.message}"

        return res.send error "'from' object is not a building" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]

        return res.send error "'from' object is not yours" if not (is_owner map.map[i1][j1][2].owner, login)
        owner = login

    try
        where = norm_id where, secret, false
        [i2, j2] = map.F where
    catch err
         return res.send error "where: #{err.message}"

    return res.send error "'where' object is not a building" if map.map[i2][j2][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
    
    owner2 = map.map[i2][j2][2].owner

    return res.send error "'from' and 'where' objects don't belong to common owner or clique" \
           if not (is_owner owner2, owner) and not (intersect i1, j1, i2, j2)
    
    return res.send error "nothing is transferred" if from == where

    lvl    = map.map[i1][j1][2].lvl
    troop  = Math.max ppl, min_troop_size m, f, w, d, g, lvl
    f_need = calculate_fuel i1, i2, lvl, troop

    return res.send error "not enough ppl: need #{troop}, have #{map.map[i1][j1][2].all}" \
           if map.map[i1][j1][2].all < troop

    ans = []

    if optimize
        [interchanges, s1, s2] = find_interchanges [i1, j1], [i2, j2], owner
        route                  = build_route interchanges, s1, s2, troop
        # check if all the interchanges are able to pay fuel
        try
            f_optimized = route_cost route, troop, true
            f_saved     = f_need - f_optimized[0]
            f_need      = ($.values f_optimized[1])[0]
            w_need      = Math.ceil f_saved / 10
            withdraw m, f + f_need, w + w_need, d, g, ppl, i1, j1
        catch err
            return res.send error err.message

        # withdraw fuel from interchanges
        for obj in f_optimized.slice 2
            $.each obj, (v, k) ->
                [i, j] = map.F k
                map.map[i][j][2].f -= v
                ans.push { id: (parseInt k), $dec: { f: v } }
    else
        w_need = 0
        # take everything from this guy
        try
            withdraw m, f + f_need, w, d, g, ppl, i1, j1
        catch err
            return res.send error err.message

    # and give it to that guy
    withdraw -m, -f, -w, -d, -g, -ppl, i2, j2

    u = undefined
    event = "tr|#{from}|#{where}|#{m}|#{f}|#{w}|#{d}|#{ppl}|#{g}"
    db.run "INSERT INTO log (time, subject, object, event) VALUES (DATETIME(), ?, ?, ?)", [owner, owner2, event], (err) -> log.notify()
    ln1 = [{ id: from,  $dec: { m: m or u, f: (f + f_need) or u, w: (w + w_need) or u, d: d or u, g: g or u, ppl: ppl or u } }]
    ln2 = [{ id: where, $inc: { m: m or u, f: f or u, w: w or u, d: d or u, g: g or u, ppl: ppl or u } }]
    set_time secret
    res.send ok ln1.concat ans, ln2

# users and bots
app.post "/api/transfer_cost", (req, res) ->
    dump req
    ###
        POST ->
            | ID        from
            | ID        where / to
            | Anything  optimize
            | Int       m
            | Int       f
            | Int       w
            | Int       d
            | Int       ppl
    ###
    [secret, from, where] = [req.body.secret, req.body.from, req.body.where or req.body.to]
    {m, f, w, d, g, ppl, optimize} = req.body
    [m, f, w, d, g, ppl] = [(parseInt m or 0), (parseInt f or 0), (parseInt w or 0), (parseInt d or 0), (parseInt g or 0), (parseInt ppl or 0)]

    return res.send error "invalid money" if not (is_qty m)
    return res.send error "invalid fuel" if not (is_qty f)
    return res.send error "invalid wood" if not (is_qty w)
    return res.send error "invalid diamonds" if not (is_qty d)
    return res.send error "invalid grain" if not (is_qty g)
    return res.send error "invalid ppl" if not (is_qty ppl)
    
    return res.send error "nothing is transferred" if m + f + w + d + g + ppl == 0

    try
        from = norm_id from, secret, true
        [i1, j1] = map.F from
    catch err
        return res.send error "from: #{err.message}"

    return res.send error "'from' object is not a building" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]

    try
        where = norm_id where, secret, false
        [i2, j2] = map.F where
    catch err
        return res.send error "where: #{err.message}"

    return res.send error "'where' object is not a building" if map.map[i2][j2][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
    
    return res.send error "nothing is transferred" if from == where

    lvl    = map.map[i1][j1][2].lvl
    troop  = Math.max ppl, min_troop_size m, f, w, d, g, lvl
    f_need = calculate_fuel i1, i2, lvl, troop

    if optimize
        [interchanges, s1, s2] = find_interchanges [i1, j1], [i2, j2], map.map[i1][j1][2].owner
        route                  = build_route interchanges, s1, s2, troop
        f_optimized            = route_cost route, troop
        
        f_saved  = f_need - f_optimized[0]
        f_need   = f_optimized
        w        = {}
        w[from]  = Math.ceil f_saved / 10
    else
        w = undefined

    res.send ok f: f_need, w: w

# users and bots
app.post "/api/work_cost", (req, res) ->
    dump req
    ###
        POST ->
            | ID    from
            | ID    where / to
            | Int   ppl
    ###
    [secret, from, where, ppl] = [req.body.secret, req.body.from, req.body.where or req.body.to, req.body.ppl]

    try
        from = norm_id from, secret, true
        [i1, j1] = map.F from
    catch err
        return res.send error "from: #{err.message}"

    return res.send error "'from' object is not a building" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]

    try
        where = norm_id where, secret, false
        [i2, j2] = map.F where
    catch err
        return res.send error "where: #{err.message}"

    return res.send error "'where' object is neither tree nor mine" if map.map[i2][j2][1] not in [_.TREE, _.MINE]

    return res.send error "invalid ppl" if not (is_qty ppl)

    lvl    = map.map[i1][j1][2].lvl
    f_need = calculate_fuel i1, i2, lvl, ppl

    res.send ok f: f_need

# users and bots
app.post "/api/tax", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID    _default / id
            | Int   tax
    ###
    [secret, id, tax] = [req.body.secret, req.body._default or req.body.id, req.body.tax]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        id = onliners[secret].aliases["home"]
        [i, j] = map.F id
    else
        try
            id = norm_id id, secret, false
            [i, j] = map.F id
        catch err
            return res.send error err.message

        return res.send error "object is not yours" if not (is_owner map.map[i][j][2].owner, onliners[secret].login)
    
    return res.send error "object is not a market" if map.map[i][j][1] not in [_.MARKET, _.FORUM]

    return res.send error "invalid tax (must be integer)" if not (is_qty tax)

    map.map[i][j][2].tax = tax/100

    set_time secret
    res.send ok()

# users and bots
app.post "/api/upgrade", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID        id
            | String    what / _default
    ###
    [secret, id, what] = [req.body.secret, req.body.id, req.body.what or req.body._default]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        id = onliners[secret].aliases["home"]
        [i, j] = map.F id
    else
        try
            id = norm_id id, secret, true
            [i, j] = map.F id
        catch err
            return res.send error err.message

        obj = map.map[i][j][1]

        return res.send error "object is not yours" if not (is_owner map.map[i][j][2].owner, login)
    
    return res.send error "object is neither tower nor castle" if obj not in [_.TOWER, _.CASTLE]

    {mf: mf, ff: ff, lvl: lvl} = map.map[i][j][2]

    what = "lvl" if not what? and obj == _.TOWER

    return res.send error "invalid upgrade type" if not (is_str what)

    what = what.trim().toLowerCase()
    m = w = d = 0

    if what == "mf" and obj == _.CASTLE
        m = Math.pow 2, mf + 1
        w = Math.floor m / 10
    else if what == "ff" and obj == _.CASTLE
        m = 0.75 * Math.pow 2, ff + 1
        w = Math.floor m / 10
    else if what == "lvl"
        w = 100 * lvl
        d = lvl
    else
        return res.send error "invalid upgrade type"

    try
        withdraw m, 0, w, d, 0, 0, i, j
        map.map[i][j][2][what] += 1
    catch err
        return res.send error err.message

    set = {}
    set[what] = map.map[i][j][2][what]
    set_time secret
    res.send ok { id: id, $dec: { m: m, w: w, d: d }, $set: set }

# users and bots
app.post "/api/upgrade_cost", (req, res) ->
    dump req
    ###
        POST ->
            | ID        _default / id
    ###
    [secret, id] = [req.body.secret, req.body._default or req.body.id]

    try
        id = norm_id id, secret, true
        [i, j] = map.F id
    catch err
        return res.send error err.message

    obj = map.map[i][j][1]

    return res.send error "object is not neither tower nor castle" if obj not in [_.TOWER, _.CASTLE]
    
    {mf: mf, ff: ff, lvl: lvl} = map.map[i][j][2]

    cost =
        lvl:
            w: 100 * lvl
            d: lvl

    if obj == _.CASTLE
        cost.mf =
            m: Math.pow 2, mf + 1
            w: Math.floor 0.100 * Math.pow 2, mf + 1
        cost.ff =
            m: 0.75 * Math.pow 2, ff + 1
            w: Math.floor 0.075 * Math.pow 2, ff + 1

    res.send ok cost

# users and bots
app.post "/api/work", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID    from
            | ID    where / to
            | Int   ppl
    ###
    [secret, from, where, ppl] = [req.body.secret, req.body.from, req.body.where or req.body.to, req.body.ppl]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        from = onliners[secret].aliases["home"]
        [i1, j1] = map.F from
        owner = onliners[secret].owner
    else
        try
            from = norm_id from, secret, true
            [i1, j1] = map.F from
        catch err
            return res.send error "from: #{err.message}"

        return res.send error "'from' object is not a building" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]

        return res.send error "'from' object is not yours" if not (is_owner map.map[i1][j1][2].owner, login)

        owner = login

    try
        where = norm_id where, secret, false
        [i2, j2] = map.F where
    catch err
        return res.send error "where: #{err.message}"

    obj = map.map[i2][j2][1]
    return res.send error "'where' object is neither tree nor mine" if obj not in [_.TREE, _.MINE]

    obj_str = if obj == _.TREE then "tree" else "mine"
    return res.send error "#{obj_str} is already empty" if map.map[i2][j2][2].qty == 0

    return res.send error "invalid ppl" if not (is_qty ppl)

    ppl = parseInt ppl

    # calculate transportation cost and send workers
    f_need = calculate_fuel i1, i2, map.map[i1][j1][2].lvl, ppl

    return res.send error "not enough ppl: need #{ppl}, have #{map.map[i1][j1][2].all}" \
           if map.map[i1][j1][2].all < ppl

    try
        withdraw 0, f_need, 0, 0, 0, 0, i1, j1
        withdraw_part i1, j1, ppl
    catch err
        return res.send error err.message

    # check if there already are workers from this place
    flag = true

    for [user, id, qty], x in map.map[i2][j2][2].ppl
        if user == owner and id == from
            map.map[i2][j2][2].ppl[x][2] += ppl
            flag = false
            break

    # add these peoples to miners list
    if flag
        map.map[i2][j2][2].ppl.push [owner, from, ppl]

    map.map[i2][j2][2].all += ppl

    set_time secret
    res.send ok [
                    {id: from,  $dec: { ppl: ppl, f: f_need } },
                    {id: where, $inc: { ppl: ppl } }
                ]

# users and bots
app.post "/api/dismiss", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID    from / _default
            | ID    where / to
            | Int   ppl
    ###
    [secret, from, where, ppl] = [req.body.secret, req.body.from or req.body._default, req.body.where or req.body.to, req.body.ppl or 1e12]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    try
        from = norm_id from, secret, false
        [i1, j1] = map.F from
    catch err
        return res.send error "from: #{err.message}"

    return res.send error "'from' object is neither tree nor mine" if map.map[i1][j1][1] not in [_.TREE, _.MINE]

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        where = onliners[secret].aliases["home"]
        [i2, j2] = map.F where
        owner = onliners[secret].owner
    else
        try
            where = norm_id where, secret, true
            [i2, j2] = map.F where
        catch err
            return res.send error "where: #{err.message}"

        return res.send error "'where' object is not a building" if map.map[i2][j2][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
        
        return res.send error "'where' object is not yours" if not (is_owner map.map[i2][j2][2].owner, login)

        owner = login

    return res.send error "invalid ppl" unless is_qty ppl

    flag = true
    for [x, y, z], I in map.map[i1][j1][2].ppl
        if x == owner and y == where
            ppl = Math.min ppl, z
            map.map[i2][j2][2].ppl[owner] = (map.map[i2][j2][2].ppl[owner] or 0) + ppl
            map.map[i2][j2][2].all += ppl
            map.map[i1][j1][2].all -= ppl
            map.map[i1][j1][2].ppl[I][2] -= ppl
            map.map[i1][j1][2].ppl.splice I, 1 if ppl == z
            flag = false
            break

    if flag
        res.send error "no workers from ##{where} at ##{from}"
    else
        set_time secret
        res.send ok [
                        {id: from,  $dec: { ppl: ppl } },
                        {id: where, $inc: { ppl: ppl } }
                    ]

# users and bots
app.post "/api/xchg", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | String    _default / what
            | ID        where / to
            | ID        from
    ###
    [secret, what, where, from]  = [req.body.secret, req.body._default or req.body.what, req.body.where or req.body.to, req.body.from]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        from = onliners[secret].aliases["home"]
        [i1, j1] = map.F from
    else
        try
            from = norm_id from, secret, true
            [i1, j1] = map.F from
        catch err
            return res.send error "from: #{err.message}"

        return res.send error "'from' object is not a building" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
        
        return res.send error "'from' object is not yours" if not (is_owner map.map[i1][j1][2].owner, login)

    try
        where = norm_id where, secret, false
        [i2, j2] = map.F where
    catch err
        return res.send error "where: #{err.message}"

    obj = map.map[i2][j2][1]
    return res.send error "'where' object is not a market" if obj not in [_.MARKET, _.FORUM]

    parsed = trade_regexp.exec what
    return res.send error "wrong exchange syntax" if not parsed

    [cy, y, cx, x] = parsed.slice 1
    [cx, cy] = [cx, cy].map (x) -> (parseInt x) or 0

    return res.send error "ambiguous exchange syntax" if not (cx ^ cy) or x == y

    return res.send error "bank doesn't sell grain" if y == "g"
    return res.send error "bank doesn't buy grain"  if x == "g"

    return res.send error "bank can't buy more than #{xchg_max_portion[x]}#{x} at a time" if cx > xchg_max_portion[x]

    tax = map.map[i2][j2][2].tax
    ans = {}
    ans.m = ans.f = ans.w = ans.d = undefined

    # skidki svoim
    tax = 0 if obj == _.FORUM and map.map[i2][j2][2].cliques[0] in map.map[i1][j1][2].cliques

    rate = xchg_rate x, y
    if cx # if we know what we have
        ans[x] = cx
        ans[y] = Math.floor cx * rate / (1 + tax)
    else # if we know what we want
        ans[x] = Math.ceil cy / rate * (1 + tax)
        ans[y] = cy
    
    return res.send error "bank can't buy more than #{xchg_max_portion[x]}#{x} (you sell #{Math.ceil ans[x]}#{x}) at a time" if ans[x] > xchg_max_portion[x]

    w_ans = {}
    w_ans[k] = ans[k] or 0 for k in ["m", "f", "w", "d"]
    w_ans[y] = -w_ans[y]

    lvl = map.map[i1][j1][2].lvl
    ppl = min_troop_size (Math.abs w_ans.m), (Math.abs w_ans.f), (Math.abs w_ans.w), (Math.abs w_ans.d), 0, lvl
    f_need = calculate_fuel i1, i2, lvl, ppl

    return res.send error "not enough ppl: need #{ppl}, have #{map.map[i1][j1][2].all}" \
           if map.map[i1][j1][2].all < ppl

    try
        # from client ...
        withdraw w_ans.m, w_ans.f + f_need, w_ans.w, w_ans.d, 0, 0, i1, j1
        # ... to bank ...
        norm_x = Math.round ans[y] / rate
        norm_y = Math.round ans[x] * rate
        map.map[i0][j0][2][x] += ans[x]
        map.map[i0][j0][2][y] -= norm_y
        # ... and market
        map.map[i2][j2][2][y] += Math.max ((norm_y - ans[y]) or (norm_x - ans[x])), 0
    catch err
        return res.send error err.message

    dec = {}
    dec[x] = ans[x]
    dec.f = (dec.f or 0) + f_need
    inc = {}
    inc[y] = ans[y]
    event = "xchg|#{from}|#{where}|#{ans[x]}#{x}|#{ans[y]}#{y}"
    db.run "INSERT INTO log (time, subject, event) VALUES (DATETIME(), ?, ?)", [login, event], () -> log.notify()
    set_time secret
    res.send ok { id: from, $dec: dec, $inc: inc }

# users and bots
app.post "/api/xchg_cost", (req, res) ->
    dump req
    ###
        POST ->
            | String    _default / what
          ( | ID        where / to )
          ( | ID        from )
    ###
    [secret, what, where, from]  = [req.body.secret, req.body._default or req.body.what, req.body.where or req.body.to, req.body.from]

    try
        from = norm_id from, secret, true
        [i1, j1] = map.F from
    catch err
        return res.send error "from: #{err.message}"

    return res.send error "'from' object is not a building" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]

    where = 1 if not where?
    try
        where = norm_id where, secret, false
        [i2, j2] = map.F where
    catch err
        return res.send error "where: #{err.message}"

    obj = map.map[i2][j2][1]
    return res.send error "'where' object is not a market" if obj not in [_.MARKET, _.FORUM]

    parsed = trade_regexp.exec what
    return res.send error "wrong exchange syntax" if not parsed

    [cy, y, cx, x] = parsed.slice 1
    [cx, cy] = [cx, cy].map (x) -> (parseInt x) or 0
    rate_flag = false
    if not cx and not cy
        cx = 1
        rate_flag = true

    return res.send error "ambiguous exchange syntax" if cx and cy or x == y

    return res.send error "bank doesn't sell grain" if y == "g"
    return res.send error "bank doesn't buy grain"  if x == "g"

    return res.send error "bank can't buy more than #{xchg_max_portion[x]}#{x} at a time" if cx > xchg_max_portion[x]

    tax = map.map[i2][j2][2].tax
    ans = {}

    # skidki svoim
    tax = 0 if obj == _.FORUM and map.map[i2][j2][2].cliques[0] in map.map[i1][j1][2].cliques

    rate = xchg_rate x, y
    if cx # if we know what we have
        ans[x] = cx
        ans[y] = cx * rate / (1 + tax)
        if ans[x] > ans[y] or rate_flag
            ans[y] = (Math.floor ans[y] * 1000) / 1000
            ans[y] = "<<1" if ans[y] == 0
        else
            ans[y] = Math.floor ans[y]
    else # if we know what we want
        ans[x] = cy / rate * (1 + tax)
        ans[y] = cy
        if ans[x] < ans[y] or rate_flag
            ans[x] = (Math.ceil ans[x] * 1000) / 1000
            ans[x] = "<<1" if ans[x] == 0
        else
            ans[x] = Math.ceil ans[x]
    
    return res.send error "bank can't buy more than #{xchg_max_portion[x]}#{x} (you sell #{Math.ceil ans[x]}#{x}) at a time" if ans[x] > xchg_max_portion[x]

    ans[x] = -ans[x]

    if from?
        lvl = map.map[i1][j1][2].lvl
        w_ans = {}
        w_ans[k] = Math.abs ans[k] or 0 for k in ["m", "f", "w", "d"]
        ppl = min_troop_size w_ans.m, w_ans.f, w_ans.w, w_ans.d, 0, lvl
        f_need = calculate_fuel i1, i2, lvl, ppl

        ans.f = (ans.f or 0) - f_need
        ans.ppl = ppl

    res.send ok ans

# users and bots
app.post "/api/new_offer", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID        id
            | String    what
    ###
    [secret, id, what] = [req.body.secret, req.body.id, req.body.what]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        id = onliners[secret].aliases["home"]
        [i, j] = map.F id
    else
        try
            [i, j] = map.F (norm_id id, secret, false)
        catch err
            return res.send error err.message

        return res.send error "object is not yours" if not (is_owner map.map[i][j][2].owner, login)

    return res.send error "object is not a market" if map.map[i][j][1] not in [_.MARKET, _.FORUM]

    parsed = trade_regexp.exec what
    return res.send error "invalid offer syntax" if not parsed

    [cy, y, cx, x] = parsed.slice 1
    return res.send error "ambiguous offer syntax" if not cx or not cy

    rebuilt = "#{cy}#{y}/#{cx}#{x}"

    for offer in map.map[i][j][2].offers
        return res.send error "duplicate offer" if offer == rebuilt

    # now we can start our intelligent adding
    # which places most delicious offer on list's top
    # first of all, let's find right (y, x) pair
    offers = (trade_regexp.exec str for str in map.map[i][j][2].offers)
    K = offers.length

    for o, k in offers
        if o[2] == y
            K = k
            break

    while K < offers.length and offers[K][2] == y
        break if offers[K][4] == x
        K++

    while K < offers.length and offers[K][2] == y and offers[K][4] == x
        break if offers[K][3] / offers[K][1] < cx / cy
        K++

    # now we can place our offer after more delicious ones
    map.map[i][j][2].offers.splice K, 0, rebuilt

    set_time secret
    res.send ok()

# users and bots
app.post "/api/del_offer", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID        id
            | String    what
    ###
    [secret, id, what] = [req.body.secret, req.body.id, req.body.what]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        id = onliners[secret].aliases["home"]
        [i, j] = map.F id
    else
        try
            [i, j] = map.F (norm_id id, secret, false)
        catch err
            return res.send error err.message

        return res.send error "object is not yours" if not (is_owner map.map[i][j][2].owner, login)

    return res.send error "object is not a market" if map.map[i][j][1] not in [_.MARKET, _.FORUM]

    return res.send error "offer not specified" if not (is_str what)

    for offer, k in map.map[i][j][2].offers
        if offer == what
            map.map[i][j][2].offers.splice k, 1
            set_time secret
            return res.send ok()

    res.send error "offer not found"

# users and bots
app.post "/api/buy", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID        where / to
            | ID        from
            | String    what
    ###
    [secret, where, from, what] = [req.body.secret, req.body.where or req.body.to, req.body.from, req.body.what]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        from = onliners[secret].aliases["home"]
        [i1, j1] = map.F from
    else
        try
            from = norm_id from, secret, true
            [i1, j1] = map.F from
        catch err
            return res.send error "from: #{err.message}"

        return res.send error "'from' object is not a building" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
        
        return res.send error "'from' object is not yours" if not (is_owner map.map[i1][j1][2].owner, login)

    try
        [i2, j2] = map.F (norm_id where, secret, false)
    catch err
        return res.send error "where: #{err.message}"

    return res.send error "'where' object is not a market" if map.map[i2][j2][1] not in [_.MARKET, _.FORUM]

    parsed = trade_regexp.exec what

    if parsed
        [cy, y, cx, x] = parsed.slice 1
        return res.send error "ambiguous buy syntax" if not (cy and not cx)

        return res.send error "market only has #{map.map[i2][j2][2][y]}#{y}" if cy > map.map[i2][j2][2][y]

        offers = (trade_regexp.exec str for str in map.map[i2][j2][2].offers)
        K = -1

        for o, k in offers
            if o[2] == y and o[4] == x
                K = k
                break

        return res.send error "market doesn't sell #{y} for #{x}" if K == -1

        remain = cy
        cx = 0
        while K < offers.length and offers[K][2] == y and offers[K][4] == x and remain
            cnt = Math.floor remain / offers[K][1]
            remain -= offers[K][1] * cnt
            cx += offers[K][3] * cnt
            K++
        cy -= remain
    else
        return res.send error "invalid buy syntax"

    ans = {}
    ans[x] = -cx
    ans[y] = cy

    lvl = map.map[i1][j1][2].lvl
    w_ans = {}
    w_ans[k] = ans[k] or 0 for k in ["m", "f", "w", "d", "g"]
    ppl = min_troop_size (Math.abs w_ans.m), (Math.abs w_ans.f), (Math.abs w_ans.w), (Math.abs w_ans.d), (Math.abs w_ans.g), lvl
    f_need = calculate_fuel i1, i2, lvl, ppl

    return res.send error "not enough ppl: need #{ppl}, have #{map.map[i1][j1][2].all}" \
           if map.map[i1][j1][2].all < ppl
    try
        # charge from client ...
        withdraw -w_ans.m, -w_ans.f + f_need, -w_ans.w, -w_ans.d, -w_ans.g, 0, i2, j2
        # ... and from market, too
        map.map[i2][j2][2][y] -= cy
        map.map[i2][j2][2][x] += cx
    catch err
        return res.send error err.message

    dec = {}
    dec[x] = cx
    dec.f = (dec.f or 0) + f_need
    inc = {}
    inc[y] = cy
    set_time secret
    res.send ok { id: from, $dec: dec, $inc: inc }

# users and bots
app.post "/api/buy_cost", (req, res) ->
    dump req
    ###
        POST ->
            | ID        where / to
            | ID        from
            | String    what
    ###
    [secret, where, from, what] = [req.body.secret, req.body.where or req.body.to, req.body.from, req.body.what]

    if from?
        try
            from = norm_id from, secret, true
            [i1, j1] = map.F from
        catch err
            return res.send error "from: #{err.message}"

        return res.send error "'from' object is not a building" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]

    try
        [i2, j2] = map.F (norm_id where, secret, false)
    catch err
        return res.send error "where: #{err.message}"

    return res.send error "'where' object is not a market" if map.map[i2][j2][1] not in [_.MARKET, _.FORUM]

    parsed = trade_regexp.exec what

    if parsed
        [cy, y, cx, x] = parsed.slice 1
        return res.send error "ambiguous buy syntax" if not (cy and not cx)

        return res.send error "market only has #{map.map[i2][j2][2][y]}#{y}" if cy > map.map[i2][j2][2][y]

        offers = (trade_regexp.exec str for str in map.map[i2][j2][2].offers)
        K = -1

        for o, k in offers
            if o[2] == y and o[4] == x
                K = k
                break

        return res.send error "market doesn't sell #{y} for #{x}" if K == -1

        remain = cy
        cx = 0
        while K < offers.length and offers[K][2] == y and offers[K][4] == x and remain
            cnt = Math.floor remain / offers[K][1]
            remain -= offers[K][1] * cnt
            cx += offers[K][3] * cnt
            K++
        cy -= remain
    else
        return res.send error "invalid buy syntax"

    ans = {}
    ans[x] = -cx
    ans[y] = cy

    if from?
        lvl = map.map[i1][j1][2].lvl
        w_ans = {}
        w_ans[k] = Math.abs ans[k] or 0 for k in ["m", "f", "w", "d", "g"]
        ppl = min_troop_size w_ans.m, w_ans.f, w_ans.w, w_ans.d, w_ans.g, lvl
        f_need = calculate_fuel i1, i2, lvl, ppl

        ans.f = w_ans.f - f_need
        ans.ppl = ppl

    res.send ok ans

# users only
app.post "/api/new_clique", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID        id
            | String    name
    ###
    [secret, id, name] = [req.body.secret, req.body.id, req.body.name]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    return no_bots res if is_bot login

    try
        id = norm_id id, secret, false
        [i, j] = map.F id
    catch err
        return res.send error err.message

    return res.send error "object must be a market" if map.map[i][j][1] != _.MARKET

    return res.send error "market is not yours" if not (is_owner map.map[i][j][2].owner, login)

    return res.send error "clique name not specified" if not (is_str name)

    name = sanitize name

    return res.send error "invalid name" if not login_regexp.test name
    
    return res.send error "clique already exists" if map.cliques[name]

    map.map[i][j][1] = _.FORUM
    map.map[i][j][2].cliques.splice 0, 0, name
    map.map[i][j][2].cliques.push "Mayors" if "Mayors" not in map.map[i][j][2].cliques
    map.cliques[name] = [i, j]
    
    db.run "INSERT INTO log (time, subject, event) VALUES (DATETIME(), ?, 'clique|#{id}|#{name}')", login, (err) -> log.notify()
    set_time secret
    return res.send ok()

# users only
app.post "/api/join", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID        id
            | String    name / _default
    ###
    [secret, id, name] = [req.body.secret, req.body.id, req.body.name or req.body._default]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    return no_bots res if is_bot login

    try
        id = norm_id id, secret, true
        [i, j] = map.F id
    catch err
        return res.send error err.message

    return res.send error "object is not a building" if map.map[i][j][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
    
    return res.send error "object is not yours" if not (is_owner map.map[i][j][2].owner, login)

    return res.send error "clique name not specified" if not (is_str name)

    name = sanitize name

    return res.send error "clique doesn't exist" if not map.cliques[name]

    # TODO: make joining confirmable by mayor
    map.map[i][j][2].cliques.push name

    # TODO: charge joining fee and show clique rules
    set_time secret
    res.send ok()

# users only
app.post "/api/leave", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID        id
            | String    name / _default
    ###
    [secret, id, name] = [req.body.secret, req.body.id, req.body.name or req.body._default]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    return no_bots res if is_bot login

    try
        id = norm_id id, secret, true
        [i, j] = map.F id
    catch err
        return res.send error err.message

    return res.send error "object is not a building" if map.map[i][j][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
    
    return res.send error "object is not yours" if not (is_owner map.map[i][j][2].owner, login)

    return res.send error "clique name not specified" if not (is_str name)

    name = sanitize name

    return res.send error "clique doesn't exist" if not map.cliques[name]

    return res.send error "you aren't a clique member" if name not in map.map[i][j][2].cliques

    return res.send error "can't remove a forum from its clique" \
           if map.map[i][j][1] == _.FORUM and map.map[i][j][2].cliques[0] == name

    return res.send error "can't remove a shared building from its clique" \
           if map.map[i][j][2].owner in map.map[i][j][2].cliques

    map.map[i][j][2].cliques.splice (map.map[i][j][2].cliques.indexOf name), 1

    set_time secret
    res.send ok()

# users only
app.post "/api/share", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID        id
            | String    name
    ###
    [secret, id, name] = [req.body.secret, req.body.id, req.body.name]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    return no_bots res if is_bot login

    try
        id = norm_id id, secret, false
        [i, j] = map.F id
    catch err
        return res.send error err.message

    return res.send error "already shared" if map.map[i][j][2].owner in map.map[i][j][2].cliques

    return res.send error "object is not a building" if map.map[i][j][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
    
    return res.send error "object is not yours" if not (is_owner map.map[i][j][2].owner, login)

    idh = onliners[secret].aliases["home"]
    return res.send error "can't share a 'home' castle" if idh == id

    return res.send error "clique name not specified" if not (is_str name)

    name = sanitize name

    return res.send error "clique doesn't exist" if not map.cliques[name]

    return res.send error "you aren't a clique member" if name not in map.map[i][j][2].cliques

    delete onliners[secret].aliases[map.map[i][j][2].name]
    map.map[i][j][2].owner = name

    set_time secret
    res.send ok()

# users only
app.post "/api/new_bot", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID    id / _default
    ###
    [secret, id] = [req.body.secret, req.body.id or req.body._default]

    return res.send error "not logged in" if not onliners[secret]

    owner = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot owner
    return no_bots res if is_bot owner

    try
        id = norm_id id, secret, true
        [i, j] = map.F id
    catch err
        return res.send error err.message

    return res.send error "object is not yours" if not (is_owner map.map[i][j][2].owner, owner)

    return res.send error "towers are fragile, better not place a bot here" if map.map[i][j][1] == _.TOWER

    try
        withdraw 0, 0, 0, 10, 0, 0, i, j
    catch err
        return res.send error err.message

    # think of a login
    login = "$bot_at#{id}"
    db.get "SELECT COUNT(*) AS cnt FROM bots WHERE login LIKE '$bot_at#{id}%'", (err, row) ->
        login += "_#{row.cnt + 1}" if row.cnt

        # think of a secret key
        bot_secret =  trimmed_hash login + timestamp()
        bot_secret += (trimmed_hash bot_secret).substr 0, 6

        # add to 'onliners' and 'bots' table in db
        db.run "INSERT INTO bots (login, secret, owner, home) VALUES (?, ?, ?, ?)", [login, bot_secret, owner, id], () ->
            onliners[bot_secret] =
                when:    0
                login:   login
                owner:   owner
                aliases: { home: id }

            set_time secret
            res.send ok login: login, secret: bot_secret

app.post "/api/mine_time", (req, res) ->
    dump req
    ###
        POST ->
            | ID    id / _default
    ###
    [secret, id] = [req.body.secret, req.body._default or req.body.id]

    try
        from = norm_id id, secret, false
        [i, j] = map.F id
    catch err
        return res.send error err.message

    return res.send error "object is not a mine" if map.map[i][j][1] != _.MINE

    I = undefined
    for v, k in map.mines
        if v[0] == i and v[1] == j
            I = k
            break
    if I?
        [a, b] = mines_check[I]
        m = (Math.max 0, a + b - days) * 10
        d = Math.floor m / 24 / 60
        m %= 24 * 60
        h = Math.floor m / 60
        m %= 60
        res.send ok next: "#{d}d:#{h}h:#{m}m"
    else
        res.send error "something went wrong"

# users only
app.post "/api/delete", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID        id
            | String    i_am_completely_sure
    ###
    {secret, id, i_am_completely_sure} = req.body

    return res.send error "not logged in" if not onliners[secret]

    owner = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot owner
    return no_bots res if is_bot owner

    try
        id = norm_id id, secret, false
        [i, j] = map.F id
    catch err
        return res.send error err.message

    return res.send error "object is not yours" if not (is_owner map.map[i][j][2].owner, owner)

    return res.send error "please confirm your request" if i_am_completely_sure != "yes"

    idh = onliners[secret].aliases["home"]
    return res.send error "can't delete a 'home' castle" if idh == id

    # delete from the map
    map.map[i][j][1] = _.VOID
    map.map[i][j][2] = {}
    # take care of aliases
    $.each onliners, (V) ->
        $.each V.aliases, (v, k) ->
            delete V.aliases[k] if v == id

    set_time secret
    res.send ok()

# users and bots
app.post "/api/plant", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID    where / to
            | ID    from
            | Int   g
    ###
    [secret, where, from, qty] = [req.body.secret, req.body.where or req.body.to, req.body.from, req.body.g]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        from = onliners[secret].aliases["home"]
        [i1, j1] = map.F from
        owner = onliners[secret].owner
    else
        try
            from = norm_id from, secret, true
            [i1, j1] = map.F from
        catch err
            return res.send error "from: #{err.message}"

        return res.send error "'from' object is not a building" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]

        return res.send error "'from' object is not yours" if not (is_owner map.map[i1][j1][2].owner, login)

        owner = login

    try
        where = norm_id where, secret, false
        [i2, j2] = map.F where
    catch err
        return res.send error "where: #{err.message}"

    return res.send error "'from' and 'where' must be in the same cluster" if i1 != i2

    return res.send error "##{where} already taken" if map.map[i2][j2][1] != _.VOID
    
    return res.send error "invalid grain" if not (is_qty qty)

    qty = parseInt qty

    ppl = min_troop_size 0, 0, 0, 0, qty, map.map[i1][j1][2].lvl
    
    return res.send error "not enough ppl: need #{ppl}, have #{map.map[i1][j1][2].all}" \
           if map.map[i1][j1][2].all < ppl

    try
        withdraw 0, 0, 0, (Math.floor qty / 5000), qty, 0, i1, j1
    catch err
        return res.send error err.message

    params =
        owner: owner
        all: 0
        stage: 1
        qty: qty

    map.map[i2][j2][1] = _.FARM
    map.map[i2][j2][2] = params

    set_time secret
    res.send ok { id: from, $dec: { g: qty } }

# users and bots
app.post "/api/harvest", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID    _default / id
    ###
    [secret, where] = [req.body.secret, req.body.id or req.body._default]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    try
        where = norm_id where, secret, false
        [i2, j2] = map.F where
    catch err
        return res.send error "where: #{err.message}"

    return res.send error "'where' object is not a farm" if map.map[i2][j2][1] != _.FARM

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        from = onliners[secret].aliases["home"]
        [i1, j1] = map.F from
        owner = onliners[secret].owner

        return res.send error "'from' and 'where' must be in the same cluster" if i1 != i2
    else
        i1 = i2
        j1 = undefined
        d = 1e15
        owner = login

        for [biome, obj, params], j in map.map[i2]
            if obj in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM] and params.owner == owner and (d2 = Math.abs j - j2) < d
                d = d2
                j1 = j
 
        return res.send error "no building of the same owner in the cluster" if not j1?

        from = map.s*i1 + j1 - map.s/2 + 1

    qty = map.map[i2][j2][2].qty

    ppl = min_troop_size 0, 0, 0, 0, qty, map.map[i1][j1][2].lvl

    return res.send error "not enough ppl: need #{ppl}, have #{map.map[i1][j1][2].all}" \
           if map.map[i1][j1][2].all < ppl

    withdraw 0, 0, 0, 0, -qty, 0, i1, j1
    map.map[i2][j2][1] = _.VOID
    map.map[i2][j2][2] = {}

    set_time secret
    res.send ok { id: from, $inc: { g: qty } }

# users and bots
app.post "/api/guard", (req, res) ->
    if onliners[req.body.secret] and (d = new Date().getTime() - onliners[req.body.secret].when) < 0 then return res.send wait -d
    dump req
    ###
        POST ->
            | ID    where / to
            | ID    from
            | Int   ppl
    ###
    [secret, where, from, qty] = [req.body.secret, req.body.where or req.body.to, req.body.from, req.body.ppl]

    return res.send error "not logged in" if not onliners[secret]

    login = onliners[secret].login

    return no_dishonest_bots res if is_dishonest_bot login
    if is_bot login
        from = onliners[secret].aliases["home"]
        [i1, j1] = map.F from
        owner = onliners[secret].owner
    else
        try
            from = norm_id from, secret, true
            [i1, j1] = map.F from
        catch err
            return res.send error "from: #{err.message}"

        return res.send error "'from' object is not a building" if map.map[i1][j1][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]

        return res.send error "'from' object is not yours" if not (is_owner map.map[i1][j1][2].owner, login)

        owner = login

    try
        where = norm_id where, secret, false
        [i2, j2] = map.F where
    catch err
        return res.send error "where: #{err.message}"

    return res.send error "'where' object is not a farm" if map.map[i2][j2][1] != _.FARM
    
    return res.send error "invalid ppl" if not (is_qty qty)

    qty = parseInt qty

    f_need = calculate_fuel i1, i2, map.map[i1][j1][2].lvl, qty

    return res.send error "not enough ppl: need #{qty}, have #{map.map[i1][j1][2].all}" \
           if map.map[i1][j1][2].all < qty

    try
        withdraw 0, f_need, 0, 0, 0, 0, i1, j1
    catch err
        return res.send error err.message

    withdraw_part i1, j1, qty
    map.map[i2][j2][2].all += qty

    set_time secret
    res.send ok [
                    { id: from,  $dec: { ppl: qty, f: f_need } },
                    { id: where, $inc: { ppl: qty } }
                ]


# give away some grain for buildings
###
consumers = {}
$.each map.map, (cluster, I) ->
    for [biome, obj, params], J in cluster
        id = map.s*I + J - map.s/2 + 1
        switch obj
            when _.TOWER, _.CASTLE, _.MARKET, _.FORUM
                consumers[id] = (consumers[id] or 0) + params.all
            when _.TREE, _.MINE
                for [x, y, z] in params.ppl
                    consumers[y] = (consumers[y] or 0) + z
$.each consumers, (g, k) ->
    [i, j] = map.F k
    map.map[i][j][2].g = 14 * g # for 14 days
###

app.listen 2411

# one day cycle
trees_set = $.uniq (i for [i, j] in map.trees when map.biomes[i] == _.PLAIN)

binSearch = (A, p) ->
    [l, r] = [0, A.length - 1]

    while l < r
        m = Math.floor (l + r)/2
        [l, r] = if p < A[m] then [l, m] else [m, r]
        return l if r - l == 1 and A[l] <= p < A[r]

setInterval () ->
    # increment days counter
    days++
    util.log "day #{days}"

    # give m and f to castles
    $.each map.map, (cluster, i) ->
        for [biome, object, params], j in cluster
            if object == _.CASTLE
                map.map[i][j][2].m += params.mf
                map.map[i][j][2].f += params.ff

    # give g to farms
    candidates = []
    P = [0]
    $.each map.map, (cluster, I) ->
        for [biome, obj, params], J1 in cluster
            if obj == _.FARM and params.stage < 4
                d = 1e15
                for [b, o, p], J2 in cluster
                    if o in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM] and p.owner == params.owner
                        d = Math.min d, Math.abs J1 - J2
                q = [1.5, 1.0, 0.5][biome - 100]
                p = q/(Math.pow d, 2)
                candidates.push [I, J1]
                P[P.length] = P[P.length - 1] + p
    if candidates.length > 0
        num_o_days = Math.max 1, Math.round 42 / P[P.length - 1]
        if days % num_o_days == 0
            x = Math.random() * P[P.length - 1]
            [i, j] = candidates[binSearch P, x]
            magic = Math.pow 1.5, 1/3
            map.map[i][j][2].qty = Math.round map.map[i][j][2].qty * magic
            stage = (map.map[i][j][2].stage += 1)
            if stage == 4
                id = map.s*i + j - map.s/2 + 1
                db.run "INSERT INTO log (time, object, event) VALUES (DATETIME(), ?, 'g|#{id}')", map.map[i][j][2].owner, () -> log.notify()

    # give w to workers
    if days % 6 == 0
        all_all = 0

        for [i, j], K in map.trees
            continue if map.map[i][j][1] != _.TREE

            portion = Math.min 20, map.map[i][j][2].qty

            # total amount of workers of this tree
            all = map.map[i][j][2].all
            all_rly = 0

            continue if all == 0

            for [x, y, z], I in map.map[i][j][2].ppl
                [ih, jh] = map.F y
                w = Math.min 5 * z, Math.round portion * z/all

                # send them home
                if map.map[ih][jh][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
                    [ih, jh] = where_to_flee i, j, x

                if ih?
                    withdraw 0, 0, -w, 0, 0, 0, ih, jh

                    f_need = calculate_fuel ih, i, map.map[ih][jh][2].lvl, z
                    try
                        withdraw 0, f_need, 0, 0, 0, 0, ih, jh
                        map.map[i][j][2].ppl[I][1] = map.s*ih + jh - map.s/2 + 1
                    catch err
                        withdraw 0, 0, 0, 0, 0, -z, ih, jh
                        map.map[i][j][2].all -= z
                        map.map[i][j][2].ppl[I][0] = 0

                    all_rly += w

            for v, k in map.map[i][j][2].ppl
                if v and v[0] == 0
                    map.map[i][j][2].ppl.splice k, 1

            map.map[i][j][2].qty -= all_rly
            all_all += all_rly

            if map.map[i][j][2].qty == 0
                # there's no use in them empty trees
                map.map[i][j][1] = _.VOID
                map.map[i][j][2] = {}

        util.log "#{all_all}w were given away"

    # give d to workers
    all_all = 0
    logins = []
    ids = []

    for [i, j], I in map.mines
        continue if map.map[i][j][1] != _.MINE
        all = map.map[i][j][2].all
        mines_check[I][1] = if all == 0 then 1e9 else Math.round 240*6/Math.sqrt all

    for [i, j], I in map.mines
        continue if map.map[i][j][1] != _.MINE
        [a, b] = mines_check[I]
        continue if a + b > days

        P = [0]
        candidates = ([I2, z] for [x, y, z], I2 in map.map[i][j][2].ppl when z >= 200)
        continue if candidates.length == 0

        for [id, z], I2 in candidates
            P[I2 + 1] = P[I2] + (Math.log z + 1) / Math.LN10

        x = Math.random() * P[P.length - 1]
        y = candidates[binSearch P, x]
        й = map.map[i][j][2].ppl[y[0]][1]

        # send them home
        [ih, jh] = map.F й
        login = map.map[i][j][2].ppl[y[0]][0]

        if map.map[ih][jh][1] not in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM]
            [ih, jh] = where_to_flee i, j, login

        if ih?
            withdraw 0, 0, 0, -1, 0, 0, ih, jh
            map.map[i][j][2].qty -= 1

            f_need = calculate_fuel ih, i, map.map[ih][jh][2].lvl, y[1]
            try
                withdraw 0, f_need, 0, 0, 0, 0, ih, jh
                map.map[i][j][2].ppl[y[0]][1] = map.s*ih + jh - map.s/2 + 1
            catch err
                withdraw 0, 0, 0, 0, 0, -y[1], ih, jh
                map.map[i][j][2].all -= y[1]
                map.map[i][j][2].ppl[y[0]][0] = 0

            logins.push login
            ids.push й
            util.log "1d to #{login} (##{й})!"

        for v, k in map.map[i][j][2].ppl
            if v and v[0] == 0
                map.map[i][j][2].ppl.splice k, 1

        mines_check[I][0] = days

        if map.map[i][j][2].qty == 0
            # there's no use in them empty mines
            map.map[i][j][1] = _.VOID
            map.map[i][j][2] = {}

    if ids.length
        logins_list = logins.join "|"
        ids_list = ids.join "|"
        db.run "INSERT INTO log (time, object, event) VALUES (DATETIME(), '#{logins_list}', 'd|#{ids_list}')", () -> log.notify()

    # charge g from buildings
    if days % 144 == 0
        consumers = {}
        $.each map.map, (cluster, I) ->
            for [biome, obj, params], J in cluster
                id = map.s*I + J - map.s/2 + 1
                switch obj
                    when _.TOWER, _.CASTLE, _.MARKET, _.FORUM
                        if not consumers[id]?
                            consumers[id]  = all: 0
                        consumers[id][id]  = (consumers[id][id] or 0) + params.all
                        consumers[id].all += params.all
                    when _.TREE, _.MINE
                        for [x, y, z] in params.ppl
                            if not consumers[y]?
                                consumers[y]  = all: 0
                            consumers[y][id]  = (consumers[y][id] or 0) + z
                            consumers[y].all += z
        $.each consumers, (g, k) ->
            [i, j] = map.F k
            delta = map.map[i][j][2].g - g.all
            if delta >= 0
                map.map[i][j][2].g = delta
            else
                map.map[i][j][2].g = 0
                part = -delta / g.all or 0
                $.each g, (v, k2) ->
                    if k2 != "all"
                        [i2, j2] = map.F k2
                        switch map.map[i2][j2][1]
                            when _.TOWER, _.CASTLE, _.MARKET, _.FORUM
                                dead = Math.round 0.42 * part * map.map[i2][j2][2].all
                                withdraw_part i, j, dead
                            when _.TREE, _.MINE
                                for [x, y, z], I in map.map[i2][j2][2].ppl
                                    if y == parseInt k
                                        dead = Math.round 0.42 * part * z
                                        map.map[i2][j2][2].ppl[I][2] -= dead
                                        map.map[i2][j2][2].all -= dead
                                        break

    # make some of them poor plain boys disappear...
    for i in trees_set
        for obj, j in map.map[i]
            if obj[1] in [_.TOWER, _.CASTLE, _.MARKET, _.FORUM, _.FARM]
                cnt = Math.min map.map[i][j][2].all, Math.floor Math.random() * 6
                withdraw_part i, j, cnt

    # dump coffers content into database
    if days % 36 == 0
        {m, f, w, d} = map.map[i0][j0][2]
        db.run "INSERT INTO coffers (time, m, f, w, d) VALUES (DATETIME(), ?, ?, ?, ?)", [m, f, w, d]

    # dump map contents onto disk
    map.backup()

, 10*60*1000

# create TCP server for remote control
connected = false
trusted = false

tcp_server = net.createServer (socket) ->
    KEY = "blueberry pony tries to achieve certain level of perfection by throwing its feces against raindrops movement"

    impostor = (socket) ->
        socket.end "Thou art an impostor, not almighty tohnann, go away!\n"

    if connected
        return impostor socket

    connected = true
    socket.write "\u001b[2J\u001b[H"
    socket.write "Welcome to the secret administrative area of Lone Lord!\n"
    socket.write "And let me congratulate thee, because if thou artn't tohnann, the almighty creator of this game,\n"
    socket.write "Thou art Mr. Impossible!\n\n"
    socket.write "Now, for me to be completely sure of thy identity,\n"
    socket.write "Wouldst thou mind entering a code phrase?\n"

    socket.on "data", (data) ->
        data = data.toString().trim()
        if data == KEY
            trusted = true
            return socket.write "Thou shalt proceed for thou verily art our lord!\n\n# "
        else if not trusted
            return impostor socket
        
        index = data.indexOf(" ")
        if index == -1
            [cmd, args] = [data, []]
        else
            [cmd, args] = [data.substr(0, index), data.substr(index + 1).split(" ")]

        switch cmd.toLowerCase()
            when "quit"
                return socket.end "Fare thee well, good Sir!\n"
            when "add"
                id = args[0]
                object = {"void": 0, "tower": 1, "castle": 2, "market": 3, "forum": 4, "tree": 10, "mine": 11}[args[1]]
                try
                    json = args.slice(2, args.length).join(" ")
                    params = JSON.parse json
                catch err
                    return socket.write "Sir, we heard that thy JSON hath these mistakes: #{err.message}.\n\n# "

                if id < map.low or id > map.high
                    return socket.write "I think, good Sir, something's wrong with thy ID argument.\n\n# "
                if not object?
                    return socket.write "Sir, I'm sorry to say that thou madest a mistake in OBJECT argument.\n\n# "

                [i, j] = map.F id
                map.map[i][j][1] = object
                map.map[i][j][2] = params
            when "info"
                id = args[0]
                
                if id < map.low or id > map.high
                    return socket.write "I think, good Sir, something's wrong with thy ID argument.\n\n# "

                [i, j] = map.F id
                obj = map.map[i][j]
                socket.write "[\n\t#{obj[0]},\n\t#{obj[1]},\n\t#{JSON.stringify obj[2]}\n]\n"
            when "edit"
                id = args[0]
                try
                    json = args.slice(1, args.length).join(" ")
                    params = JSON.parse json
                catch err
                    return socket.write "Sir, we heard that thy JSON hath these mistakes: #{err.message}.\n\n# "

                if id < map.low or id > map.high
                    return socket.write "I think, good Sir, something's wrong with thy ID argument.\n\n# "

                [i, j] = map.F id
                $.each params, (v, k) ->
                    map.map[i][j][2][k] = v
            else
                return socket.write "Thy command, Sir, wasn't understood. Kindly try again.\n\n# "

        socket.write "Gladly done, Sir!\n\n# "

    socket.on "end", () ->
        connected = false
        trusted = false

tcp_server.listen 9999

util.log "ready to serve"
