fs = require "fs"
mailer = require "nodemailer"

crypto = require "crypto"

md5 = (string)    -> ((crypto.createHash "md5").update string).digest "hex"
hash = (password) -> md5 "lone" + (md5 password) + "lord"

trimmed_hash = (str) ->
        h_str = hash str
        h_str[0] + h_str[1] + h_str[2] + h_str[4] + h_str[6] + h_str[10] + h_str[12] + h_str[16] + h_str[18] + h_str[28]

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

db = ((fs.readFileSync "users.txt", "utf8").split "\n").map (s) -> s.split "|"

smtpTransport = mailer.createTransport "SMTP",
    service: "Gmail"
    user: "lonelord@retloko.org"
    pass: "*****"

for [login, email, pwd, ts] in db[0..db.length - 3]
    code = encode_code trimmed_hash login + ts
    link = "http://lonelord.retloko.org/confirm/#{code}"
    text = "Dear #{login},\n\nLast time we were unable to create your castle in the Lone lord game.\nWe apologise for that inconvenience and send you confirmation link again. After you click it, your castle will be properly created and you can play the game.\n#{link}"

    options =
        from: "Lonelord Confirmation <lonelord@retloko.org>"
        to: email
        subject: "Confirmation link"
        text: text

    smtpTransport.sendMail options, () -> 0
    console.log "#{email}... OK"
