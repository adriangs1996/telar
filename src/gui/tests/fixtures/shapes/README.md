# Rounded rectangle reference

`cases.json` describes 17 ordered quads in physical pixels on a 640 by 480
opaque target. Cases include square fills, chips, rounded cards, transparent
rings, fractional bounds/borders, clamped radii, narrow shapes, item opacity
and overlapping translucent layers.

`rounded-rectangles.png` was rendered from the original Metal quad shader,
with its canvas radius clamp and straight-alpha blend factors, a one-pixel
opaque alpha atlas and a BGRA8-unorm target. That shader and the reference
tool are gone, so the fixture is frozen: change it only with a new reference.

The committed fixture supports tests on both platforms.
`gui-rounded-rectangle-test` keeps physical shapes constant while adapting
logical coordinates to each device scale. It checks the atlas, parent
clipping/reparenting, invalid properties, empty geometry and restoration after
style changes. The capture window has fixed size hints so a compositor
can preserve the reference dimensions.

Metal comparisons require exact pixels. Software and OpenGL allow one channel
level per composited quad covering a pixel, including a maximum of two only
where the two translucent quads overlap. Pixels outside all quads must remain
exact. This records backend rounding; it does not establish full cross-platform
visual equivalence.
