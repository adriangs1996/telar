#include <stdint.h>
#include "../native/telar_gui.h"

_Static_assert(sizeof(telar_gui_quad) == 80, "GLSL std430 Quad stride");
_Static_assert(offsetof(telar_gui_quad, u0) == 16, "GLSL Quad UV offset");
_Static_assert(offsetof(telar_gui_quad, r) == 32, "GLSL Quad color offset");
_Static_assert(offsetof(telar_gui_quad, radius) == 48, "GLSL Quad shape offset");
_Static_assert(offsetof(telar_gui_quad, border_r) == 64, "GLSL Quad border color offset");

const uint32_t telar_gui_quad_vert_spv[] =
#include "quad.vert.inc"
;
const uint32_t telar_gui_quad_vert_spv_bytes = sizeof telar_gui_quad_vert_spv;

const uint32_t telar_gui_quad_frag_spv[] =
#include "quad.frag.inc"
;
const uint32_t telar_gui_quad_frag_spv_bytes = sizeof telar_gui_quad_frag_spv;
