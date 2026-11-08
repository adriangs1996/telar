# Rounded rectangle reference

`cases.json` describes 17 ordered quads in physical pixels on a 640 by 480
opaque target. Cases include square fills, chips, rounded cards, transparent
rings, fractional bounds/borders, clamped radii, narrow shapes, item opacity
and overlapping translucent layers.

`rounded-rectangles.png` comes from the unchanged
`lib/window/shaders/quad.metal` vertex and fragment functions. The reference
tool applies the original canvas radius clamp and straight-alpha blend
factors, uses a one-pixel opaque alpha atlas and reads the BGRA8-unorm target.
It compiles MSL 4.0 and submits through the classic Metal command encoder;
it does not reproduce the original Metal 4 submission code. Separate live
captures compare against the actual original application.

On a Mac with the required Metal SDK, regenerate the fixture from the repository
root:

```sh
clang++ -std=c++23 -fobjc-arc -Wall -Wextra -Werror \
  -framework Foundation -framework Metal -framework ImageIO -framework CoreGraphics \
  services/gui-cpp/tools/rounded_rectangle_reference.mm \
  -o /tmp/telar-rounded-rectangle-reference
/tmp/telar-rounded-rectangle-reference \
  lib/window/shaders/quad.metal \
  services/gui-cpp/tests/fixtures/shapes/cases.json \
  services/gui-cpp/tests/fixtures/shapes/rounded-rectangles.png
```

The committed fixture supports tests on both platforms without compiling this
Mac-only tool. `gui-rounded-rectangle-test` keeps physical shapes constant
while adapting logical coordinates to each device scale. It checks the atlas,
parent clipping/reparenting, invalid properties, empty geometry and restoration
after style changes. The capture window has fixed size hints so a compositor
can preserve the reference dimensions.

Metal comparisons require exact pixels. Software and OpenGL allow one channel
level per composited quad covering a pixel, including a maximum of two only
where the two translucent quads overlap. Pixels outside all quads must remain
exact. This records backend rounding; it does not establish full cross-platform
visual equivalence.
