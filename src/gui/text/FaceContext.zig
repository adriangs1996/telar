//! What opening any face of one atlas needs: the FreeType library, the
//! options the atlas was opened with and the shared alpha page. Discovered
//! faces are opened with these after startup, so the set keeps one copy.
const std = @import("std");
const freetype = @import("freetype");
const AtlasOptions = @import("AtlasOptions.zig");
const FaceContext = @This();

library: freetype.c.FT_Library,
options: AtlasOptions,
pixels: []u8,
