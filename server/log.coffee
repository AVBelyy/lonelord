$      = require "underscore"
fs     = require "fs"
engine = require "engine.io"

server = engine.listen 2511

logins = {}
windows = {}
news = fs.readFileSync("motd.txt", "utf8")
db = module.parent.exports.get_db()

exports.is_client = (login) -> windows[login] > 0

exports.get_users = () -> $.filter ($.uniq $.values logins), (x) -> x?

broadcast = (data, id) ->
    $.each server.clients, (v) ->
        v.send data unless v.id == id

exports.notify = () ->
    db.get "SELECT * FROM log ORDER BY time DESC LIMIT 1", (err, row) ->
        data = [[row.time, row.subject, row.object, row.event]]
        broadcast "L," + JSON.stringify data

server.on "connection", (socket) ->
    id = socket.id

    socket.on "message", (data) ->
        return unless typeof data == "string"

        i = data.indexOf ","
        [cmd, arg] = [(data.substr 0, i), (data.substr i+1)]

        switch cmd[0]
            when "R" # register
                if not windows[arg]
                    broadcast "O,#{arg}", id
                    windows[arg] = 1
                else
                    windows[arg]++
                logins[id] = arg
            when "D" # deregister
                if login = logins[id]
                    # disconnect all clients with the same login
                    $.each logins, (v, k) ->
                        if v == login
                            server.clients[k].close()
            when "M" # message
                from = logins[id]
                return socket.send "E,not logged in" unless from?

                to = cmd.substr 1
                if to == "*"
                    broadcast "M#{from},#{arg}", id
                else if to == "admin" and from == "tohnann"
                    i = arg.indexOf " "
                    [action, parameter] = [(arg.substr 0, i), (arg.substr i+1)]
                    switch action
                        when "news"
                            news = parameter
                            broadcast "N," + news
                        else
                            socket.send "E,unknown admin command"
                else
                    # check among engine.io logins if 'to' user is online
                    flag = true
                    $.each logins, (v, k) ->
                        if v == to
                            flag = false
                            server.clients[k].send "m#{from},#{arg}"
                    socket.send "E,user is offline or doesn't exist" if flag
            when "L" # global log
                socket.send "N," + news
                db.all "SELECT * FROM log WHERE time >= DATETIME('now', '-1 day') ORDER BY time", (err, rows) ->
                    output = []
                    rows.forEach (row) ->
                        if not arg or row.object == arg
                            output.push [row.time, row.subject, row.object, row.event]
                    socket.send "L," + JSON.stringify output

    socket.on "close", () ->
        if login = logins[id]
            windows[login]--
            if not windows[login]
                setTimeout (() -> broadcast "o,#{login}", id), 0
            delete logins[id]
