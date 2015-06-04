fs     = require "fs"
jade   = require "jade"
stylus = require "stylus"
uglify = require "uglify-js"
coffee = require "coffee-script"

# firstly, let's compile jade templates
views = fs.readdirSync "views/"
for view in views
    if /\.jade$/.test view
        fs.writeFileSync "../static/#{view.replace('.jade', '.html')}",
            (jade.compile (fs.readFileSync "views/#{view}", "utf8"), filename: "views/#{view}")()
# secondly, stylus stylesheets
csses = fs.readdirSync "../static/css/"
for css in csses
    if /\.styl$/.test css
        stylus(fs.readFileSync "../static/css/#{css}", "utf8")
            .set("compress", true)
            .render (err, compiled) ->
                fs.writeFileSync "../static/css/#{css.replace('.styl', '.css')}", compiled
# and, thirdly, coffee scripts
scripts = fs.readdirSync "../static/js/"
for script in scripts
    if /\.coffee$/.test script
        js = coffee.compile (fs.readFileSync "../static/js/#{script}", "utf8"), bare: true
        fs.writeFileSync "../static/js/#{script.replace('.coffee', '.min.js')}",
            (uglify.minify js, fromString: true).code
