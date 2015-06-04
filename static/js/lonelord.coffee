$ () ->
    # constants
    sc_ratio = 473/294

    all_commands = "register|login|logout|show|info|users|bots|days|mine_time|aliases|build|upgrade|rename|attack|delete|hire|work|dismiss|transfer|move|burn|plant|harvest|guard|buy|xchg|new_offer|del_offer|tax|new_clique|join|leave|share|new_bot|build_cost|upgrade_cost|attack_cost|work_cost|transfer_cost|buy_cost|xchg_cost".split "|"

    [VOID, TOWER, CASTLE, MARKET, FORUM, FARM] = [0..5]
    [TREE, MINE] = [10..11]

    cmd_regexp = /^\s*\$\w+\s*$/
    dir_regexp = /^\s*(<|>)(\d*)\s*$/

    # html elements
    castle = $ "#castle"
    scroll = $ "#scroll"
    copyright = $ "#copyright"
    content = $ "#content"
    links = $ "#links"
    header = $ "#header"
    arrows = $ ".arrow"
    show_left = $ "#show_left"
    map = $ "#map"
    show_right = $ "#show_right"
    tiles = $ ".tile"
    objects = $ ".tile >.object"
    console = $ "#console"
    log = $ "#log"
    tabs = $ ".tab"
    text = $ ".text"
    [t1, t2, t3] = [($ "#t1"), ($ "#t2"), ($ "#t3")]
    input = $ "#input >input"
    brackets = $ ".bracket"
    greeting = $ "#greeting"
    confirmation = $ "#confirmation"
    first_day = $ "#first_day"
    refresh = $ "#refresh"

    brackets.remove() if compact

    soc = {0: "void", 1: "tower", 2: "castle", 3: "market", 4: "forum", 5: "farm", 10: "tree", 11: "mine", 100: "swamp", 101: "plain", 102: "desert"}

    # 'global' vars
    history   = if localStorage.history then JSON.parse localStorage.history else [""]
    cur_line  = history.length - 1
    cur_tab   = 1
    cluster   = null
    secret    = undefined
    login     = null
    admin     = []
    socket    = null
    cmd_cnt   = 0
    chat_conn = false

    if font = localStorage.font
        log.css "fontFamily", font
        input.css "fontFamily", font
        ($ "#tabs").css "fontFamily", font

    resize_signs = () ->
        co_width = content.width()

        ($ ".ppl").css
            fontSize: 10/813*co_width
        ($ ".tower-name").css
            fontSize: 10/813*co_width
        ($ ".castle-name").css
            fontSize: 10/813*co_width
        ($ ".market-name").css
            fontSize: 4/271*co_width
        ($ ".forum-name").css
            fontSize: 4/271*co_width
        ($ ".lvl").css
            fontSize: 16/813*co_width
        ($ ".id").css
            fontSize: 10/813*co_width

    handlers =
        register: (req, res) ->
            writeln "response", confirmation.html()

        login: (req, res) ->
            secret = res.data.secret
            login  = req._default or req.login
            {admin, n} = res.data
            localStorage.login  = login
            localStorage.secret = secret

            # register on chat server
            socket.send "R,#{login}"

            # show home castle on map
            send_msgs [["$show", "home"]], 0, () ->
                if n
                    if n <= 500
                        writeln "response", "<span style='color:green'>As a user ##{n} you will receive a 1.5x starting resources bonus!</span>"
                    writeln "response", first_day.html()

        logout: (req, res) ->
            secret = undefined
            login  = null
            delete localStorage.login
            delete localStorage.secret

            # deregister on chat server
            socket.send "D,"

        show: (req, res) ->
            ppl_text = (obj, params) ->
                switch obj
                    when TOWER, CASTLE
                        "#{params.owner}<br/>" + ("#{params.ppl.thy or ""}#{if params.ppl.thy != params.ppl.all then '('+params.ppl.all+')' else ''}" or "0")
                    when MARKET, FORUM
                        "#{params.owner}<br/>#{(Math.floor params.tax*100)}% tax"
                    when TREE, MINE
                        "qty: #{params.qty}<br/>#{params.ppl.thy or ""}(#{params.ppl.all})"
                    when FARM
                        "qty: #{params.qty}<br/>(#{params.all})"

            {cluster, biome} = res.data
            if cluster == -375 then show_left.hide() else show_left.show()
            if cluster ==  375 then show_right.hide() else show_right.show()
            map.removeClass().addClass soc[biome]
            for [biome, object, params], x in res.data.objects
                ($  tiles[x] ).removeClass()
                              .addClass "tile #{soc[biome]}"
                ($ objects[x]).removeClass()
                              .addClass "object #{soc[object]} #{if params.stage then 'g'+params.stage else ''}"
                ($ ".id",   objects[x]).html "##{8*cluster + x - 3}"
                ($ ".ppl",  objects[x]).removeClass()
                                       .addClass("ppl #{soc[object]}-ppl")
                                       .addClass(if params.owner == login or params.owner in admin then "thy" else "")
                                       .addClass(if params.shared then "shared" else "")
                                       .html (ppl_text object, params)
                ($ ".name", objects[x]).removeClass()
                                       .addClass("name #{soc[object]}-name")
                                       .html params.name
                ($ ".lvl",  objects[x]).removeClass()
                                       .addClass("lvl #{soc[object]}-lvl")
                                       .html params.lvl
            resize_signs()

        new_clique: (req, res) ->
            admin.push sanitize req.name

    sanitize = (txt) ->
        (((txt.replace /&/g, "&amp;").replace /</g, "&lt;").replace />/g, "&gt;").replace /"/g, "&quot;"

    colorize = (request, cmd = "") ->
        walk = (obj, depth) ->
            if typeof obj != "object" or obj is null
                if typeof obj == "string"
                    if obj in ["ok", "victory"]
                        "<span class='ok'>#{obj}</span>"
                    else if obj in ["error", "defeat"]
                        "<span class='error'>#{obj}</span>"
                    else
                        "<span class='quoted'>#{sanitize obj}</span>"
                else
                    if depth == 4 and cmd == "show" \
                    or depth == 3 and cmd == "info"
                        "<span class='constant'>#{soc[obj].toUpperCase()}</span>"
                    else
                        "<span class='number'>#{obj}</span>"
            else if obj instanceof Array
                walk el, depth + 1 for el in obj
            else
                out = {}
                $.each obj, (k, v) ->
                    if k != "secret" or cmd == "new_bot"
                        biome = k == "biome"
                        v = "***" if k == "password"
                        k = if k[0] == "$" and depth == 0 then "<span class='command'>#{k}</span>" \
                                                          else "<span class='param'>#{k}</span>"
                        if biome and depth == 1
                            out[k] = "<span class='constant'>#{soc[v].toUpperCase()}</span>"
                        else
                            out[k] = walk v, depth + 1
                    true
                out

        output = JSON.stringify (walk request, 0), null, 1
        (output.replace /"</g, "<").replace />"/g, ">"
    
    writeln = (type, txt, t = t1, att = false) ->
        line = ($ "<p/>", class: type).html txt
        if t == t3
            t3.prepend line
        else
            t.append line
            t.get(0).scrollTop = t.get(0).scrollHeight
        # blink the tab
        if att
            to_tab = parseInt (t.attr "id")[1]
            if to_tab != cur_tab
                ($ "#tab#{to_tab}").addClass "attention"

    send_msg = (request, cb) ->
        cmd_cnt++
        [cmd, args] = request
        cmd = cmd.toLowerCase()
        if typeof args != "object" or args instanceof Array
            args = _default: args
        args.secret = args.secret or secret

        $.ajax
            url: "/api/#{cmd}",
            type: "POST"
            data: args
            error: (xhr, status, code) ->
                if xhr.status == 403
                    writeln "error", refresh.html()
                else if xhr.status == 404
                    writeln "error", "Network Error: invalid command <b>$#{cmd}</b>"
                else
                    msg = "Something went wrong (error #{xhr.status})"
                    writeln "error", "Network Error: #{msg}"
            success: (data) ->
                writeln "response", colorize data, cmd
                handlers[cmd] args, data if handlers[cmd] and data.status == "ok"
                if data.status == "error" and cmd_cnt == 1 and cmd == "login" and data.data == "incomplete information"
                    writeln "response", "<span style='color:green'>Hint</span>: something on API server went wrong recently and we were unable to restore information for your quick login. Login again manually, typing both login and password."
            complete: cb

    send_msgs = (cmds, pos, final = () -> 0) ->
        return final() if pos == cmds.length
        request = {}
        [k, v] = cmds[pos]
        if k[0] == "$"
            ($ "#tab1").click()
            # command to server
            request[k] = v
            writeln "request", colorize request
            send_msg [(k.substr 1), v], () -> send_msgs cmds, pos + 1, final
        else if k[0] == "#"
            ($ "#tab1").click()
            if (k.substr 1) == "font"
                localStorage.font = v.toString()
                writeln "response", "<span style='color:green'>Choice remembered.</span><br>To fall back to a default font, type: <b>#font: \"\"</b>"
        else
            # message to user
            if chat_conn
                v = v.toString()
                ($ "#tab2").click()
                if login
                    if k == "*"
                        writeln "chat", "<span style='color:green'>#{login}</span>: #{sanitize v}", t2
                    else
                        writeln "chat", "<b><span style='color:green'>#{login}->#{k}</span>: #{sanitize v}</b>", t2
                socket.send "M#{k},#{v}"
            else
                writeln "error", refresh.html(), t2, true
            send_msgs cmds, pos + 1, final

    show_left.click () ->
        send_msgs [["$show", (cluster-1)*8]], 0

    show_right.click () ->
        send_msgs [["$show", (cluster+1)*8]], 0

    objects.click () ->
        id = parseInt $(".id", this).html().substr 1
        send_msgs [["$info", id]], 0

    tabs.click (e) ->
        return if ($ this).hasClass "active"
        cur_tab = parseInt this.id[3]
        text.css display: "none"
        ($ "#t#{cur_tab}").css display: "block"
        tabs.removeClass "active"
        (($ this).addClass "active").removeClass "attention"
        if cur_tab == 2
            input.attr "placeholder", "press '/' and type your message in quotes"
        else
            input.attr "placeholder", "type a JSON request in without braces"
        if cur_tab == 3
            input.parent().hide()
        else
            input.parent().show()
            input.focus()

    input.keydown (e) ->
        switch e.which
            when 38
                if cur_line > 0
                    history[cur_line--] = this.value
                    this.value = history[cur_line]
                    e.preventDefault()
            when 40
                if cur_line < history.length - 1
                    history[cur_line++] = this.value
                    this.value = history[cur_line]
                    e.preventDefault()
            when 13
                txt = this.value.trim()
                if txt
                    cur_line = history.length - 1
                    history[cur_line++] = txt
                    history[cur_line] = ""
                    if cmd_regexp.test txt
                        txt = txt + ': ""'
                    if dir_parsed = dir_regexp.exec txt
                        [dir, step] = dir_parsed.slice 1
                        [dir, step] = [{"<": -1, ">": 1}[dir], (parseInt step) or 1]
                        txt = "{$show: #{8*(cluster + dir*step)}}"
                    if txt[0] != "{" or txt[txt.length-1] != "}"
                        txt = "{" + txt + "}"
                    try
                        json = jsonlite.parse txt
                        this.value = ""
                        commands = []
                        $.each json, (k, v) -> commands.push [k, v]
                        send_msgs commands, 0
                    catch error
                        to = $ "#t#{cur_tab}"
                        writeln "request", txt, to
                        writeln "error", "Syntax Error: #{error.message}", to
                false
            when 9
                ln = this.value
                end = this.selectionStart
                start = 1 + ln.lastIndexOf "$", end
                if start
                    tab = $ "#t#{cur_tab}"
                    substr = ln.substring start, end
                    if /^\w*$/.test substr
                        found = (cmd for cmd in all_commands when substr == cmd.substr 0, substr.length)
                        if found[0] == substr
                            writeln "response", "<span style='color:green'>Hint: </span>see command's description <a href='/wiki/index.php/API#.24#{substr}' target='_blank'>here</a>.", tab
                        else if found.length == 1
                            this.value = (ln.substr 0, end) + (found[0].substr substr.length) + (ln.substr end)
                            pos = end + found[0].length - substr.length
                            this.setSelectionRange pos, pos
                        else
                            writeln "response", (colorize found), tab
                false
            when 191
                if this.value == ""
                    this.value = "*: \"\""
                    this.setSelectionRange 4, 4
                    false

    input.focus () -> brackets.show()
    input.blur  () -> brackets.hide()

    on_resize = () ->
        [ca_width, ca_height] = [castle.width(), castle.height()]

        if ca_width/sc_ratio > ca_height
            [sc_width, sc_height] = [ca_height*sc_ratio, ca_height]
        else
            [sc_width, sc_height] = [ca_width, ca_width/sc_ratio]
        if compact
            [co_width, co_height] = [sc_width, sc_height]
        else
            [co_width, co_height] = [sc_width*0.75, sc_height*0.60]

        scroll.css
            top:  (ca_height - sc_height)/2
            left: (ca_width - sc_width)/2
        if not compact
            content.css
                top:  (sc_height - co_height)/2
                left: (sc_width - co_width)/2*0.9
        scroll.width sc_width
        scroll.height sc_height
        copyright.css fontSize: 4/271*sc_width
        log.css       fontSize: 7/418*co_width
        links.css     fontSize: 4/271*co_width
        header.css    fontSize: 13/203*co_width
        input.css     fontSize: 6/209*co_width
        brackets.css  fontSize: 10/209*co_width
        ($ ".tile >.object").css
            top:  (1-0.90)/2*tiles.height()
            left: (1-0.85)/2*tiles.width()
        resize_signs()
        t1.get(0).scrollTop = t1.get(0).scrollHeight
        t2.get(0).scrollTop = t2.get(0).scrollHeight

    ($ window).resize on_resize
    on_resize()

    if location.hash.substr 1
        [l, c] = (location.hash.substr 1).split ";"
        location.hash = ""
        if l and c
            send_msgs [["$login", login: l, password: " ", secret: "-#{c}"]], 0
    else if localStorage.login
        secret = localStorage.secret
        send_msgs [["$login", localStorage.login]], 0
    else
        send_msgs [["$show", 0]], 0, () ->
            writeln "response", greeting.html()


    window.onbeforeunload = (e) ->
        if len = history.length > 500
            history = history.slice len - 500
        localStorage.history = JSON.stringify history

        return

    input.focus()

    socket = new eio.Socket "ws://#{location.hostname}:2511/"
    socket.on "open", () ->
        chat_conn = true

        socket.on "message", (data) ->
            return unless typeof data == "string"

            i = data.indexOf ","
            [cmd, arg] = [(data.substr 0, i), (data.substr i+1)]

            switch cmd[0]
                when "O" # online
                    writeln "chat", "<i><b>#{arg}</b> is online</i>", t2
                when "o" # offline
                    writeln "chat", "<i><b>#{arg}</b> is offline</i>", t2
                when "E" # error
                    writeln "error", "Chat Error: #{sanitize arg}", t2, true
                when "M" # global message
                    from = cmd.substr 1
                    writeln "chat", "<span style='color:green'>#{from}</span>: #{sanitize arg}", t2, true
                when "m" # private message
                    from = cmd.substr 1
                    writeln "chat", "<b><span style='color:green'>#{from}->#{login}</span>: #{sanitize arg}</b>", t2, true
                when "N" # news
                    writeln "response", "<b><span style='color:green'>#{arg}</span></b>", t2, true if arg
                when "L" # global log
                    norm = (n) -> if n < 10 then "0#{n}" else "#{n}"

                    events = JSON.parse arg
                    tz_offset = -new Date().getTimezoneOffset()
                    h_offset = tz_offset / 60
                    m_offset = tz_offset % 60
                    for [datetime, subject, objects_str, event] in events
                        objects_list = (objects_str or "").split "|"
                        [h, m, s] = ((datetime.split " ")[1].split ":").map (x) -> parseInt x
                        m += m_offset
                        h = norm (h + (h_offset + Math.floor m / 60)) % 24
                        m = norm m % 60
                        [type, args...] = event.split "|"

                        switch type
                            when "reg"
                                msg = "<span style='color:green'>New user</span> <b>#{subject}</b> registered!"
                            when "build"
                                msg = "<span style='color:#61360d'>New building</span> by <b>#{subject}</b> at <b>##{args[0]}</b>"
                            when "defeat"
                                msg = "<span style='color:#ccac00'>Repelled attack</span> from <b>##{args[0]}</b> (-#{args[2]} ppl) to <b>##{args[1]}</b> (-#{args[3]} ppl)"
                            when "victory"
                                booty = args.slice 4
                                b_list = []
                                letters = ["m", "f", "w", "d", "g"]
                                for qty, i in booty
                                    b_list.push "<b>#{qty}</b>#{letters[i]}" if parseInt qty
                                msg = "<span style='color:red'>Victorious attack</span> from <b>##{args[0]}</b> (-#{args[2]} ppl) to <b>##{args[1]}</b> (-#{args[3]} ppl), #{if b_list.length then 'booty: '+(b_list.join ', ') else 'no booty'}"
                            when "clique"
                                msg = "<span style='color:violet'>New clique</span> <b>#{args[1]}</b> at <b>##{args[0]}</b>"
                            when "tr"
                                transferred = args.slice 2
                                t_list = []
                                letters = ["m", "f", "w", "d", "ppl", "g"]
                                for qty, i in transferred
                                    t_list.push "<b>#{qty}</b>#{letters[i]}" if parseInt qty
                                msg = "<span style='color:#00a7eb'>Transfer</span> from <b>##{args[0]}</b> to <b>##{args[1]}</b> of #{t_list.join ', '}"
                            when "xchg"
                                msg = "<span style='color:#6e0b74'>Exchange</span> from <b>##{args[0]}</b> at <b>##{args[1]}</b>: <b>#{args[2]}</b> → <b>#{args[3]}</b>"
                            when "d"
                                msg = "<span style='color:blue'>DIAMOND!</span> to <b>##{args.join ", #"}</b>"
                            when "g"
                                msg = "<span style='color:#50900d'>Harvest time</span> at <b>##{args[0]}</b>"

                        own = login in objects_list
                        writeln "log #{if own then 'thy_log' else ''}", "#{h}:#{m}:#{norm s} - #{msg}", t3, own and events.length == 1

        socket.on "close", () ->
            chat_conn = false
            writeln "error", refresh.html(), t1
            writeln "error", refresh.html(), t2

        # request global log
        socket.send "L,"
