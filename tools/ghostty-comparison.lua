local t = require('telar')
return { api_version = 2, client = { sidebar = { visible = false, renderer = 'cells' }, pane_gaps = false, bars = { bottom = { left = t.bar.static(' '), center = t.bar.static(' '), right = t.bar.tabs() } } }, gui = { font = { family = 'JetBrains Mono', size = 15 }, window = { padding = { x = 0, y = 0 }, background_opacity = 1 }, cursor = { blink = false } } }
