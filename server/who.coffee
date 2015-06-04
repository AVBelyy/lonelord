#!/usr/bin/env coffee

sqlite = require "sqlite3"

db = new sqlite.Database "lonelord.db"

db.get "SELECT login, email, password, DATETIME(last_login, 'unixepoch', '+4 hours') AS last_login, home FROM users WHERE login = ?", process.argv[2], (err, row) ->
    console.log row
    db.close()
