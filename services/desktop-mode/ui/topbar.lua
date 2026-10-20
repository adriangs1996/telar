local ui = telar.ui

local background = ui.path({
  x = 8,
  y = 3,
  width = 1240,
  height = 40,
  path = "M 0 0 L 220 0 C 240 0 228 30 204 30 L 18 30 C 4 30 0 18 0 0 Z",
  fill = "#1e1e2e",
  opacity = 1,
})

local telar_text = ui.text({
  parent = background,
  text = "Telar",
  color = "#cdd6f4",
  x = 14,
  y = 6,
  ["font.pixelSize"] = 14,
})

ui.on(background, "hover", function(event)
  ui.animate(background, "opacity", {
    to = event.inside and 1 or 0.8,
    duration_ms = 160,
    easing = "out_cubic",
  })

  ui.animate(telar_text, "x", {
    to = event.inside and 100 or 14,
    duration_ms = 200,
    easing = "out_cubic",
  })
end)
