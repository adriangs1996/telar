//! Fixed fallback order for resident faces; installed-font discovery runs
//! only where a run is first shaped, never while painting a warm frame.
const std = @import("std");
const freetype = @import("freetype");
const assets = @import("assets");
const FontFace = @import("FontFace.zig");
const FaceContext = @import("FaceContext.zig");
const FallbackFace = @import("FallbackFace.zig");
const FallbackPool = @import("FallbackPool.zig");
const GraphemeMisses = @import("GraphemeMisses.zig");
const AtlasOptions = @import("AtlasOptions.zig");
const FontMatch = @import("../native/FontMatch.zig").FontMatch;
const Id = @import("font_id.zig").Id;
const FontSet = @This();

var next_identity: std.atomic.Value(u64) = .init(1);

/// The native port answering which installed face covers one grapheme.
pub const Lookup = *const fn (text: [*:0]const u8, match: *FontMatch) callconv(.c) c_int;

extern fn telar_gui_find_fallback_font(text: [*:0]const u8, match: *FontMatch) callconv(.c) c_int;

/// The platform port: CoreText on macOS, Fontconfig on Linux.
pub const native_lookup: Lookup = telar_gui_find_fallback_font;

/// The longest UTF-8 grapheme a lookup queries, after dropping joiners
/// and selectors; longer clusters keep the replacement glyph.
pub const max_query_bytes = 64;

/// Never reused, including when a replacement set occupies the same address.
identity: u64,
/// Changes only when the resident fallback order changes, not on rasterization.
revision: u64 = 0,
primary: FontFace,
text: ?FontFace,
symbols: FontFace,
sans: FontFace,
sans_semibold: FontFace,
context: FaceContext,
pool: FallbackPool = .{},
misses: GraphemeMisses = .{},
lookup: Lookup = native_lookup,
/// Native lookups made so far; tests prove a grapheme is looked up once.
lookups: usize = 0,

/// Loads the configured face plus embedded text, symbols and the two chrome
/// sans weights, sharing one page. Discovered faces join later.
/// Example: `var fonts = try FontSet.init(library, options, pixels);`
pub fn init(library: freetype.c.FT_Library, options: AtlasOptions, pixels: []u8) !FontSet {
    const identity = try allocateIdentity(&next_identity);
    var primary = try FontFace.init(library, options, pixels);
    errdefer primary.deinit();
    var fallback = options;
    fallback.face_index = 0;
    fallback.postscript = "";
    fallback.font = assets.jetbrains_mono;
    var text: ?FontFace = if (std.mem.eql(u8, options.font, assets.jetbrains_mono)) null else try FontFace.init(library, fallback, pixels);
    errdefer if (text) |*face| {
        face.deinit();
    };
    fallback.font = assets.nerd_symbols;
    var symbols = try FontFace.init(library, fallback, pixels);
    errdefer symbols.deinit();
    fallback.font = assets.plex_sans;
    var sans = try FontFace.init(library, fallback, pixels);
    errdefer sans.deinit();
    fallback.font = assets.plex_sans_semibold;
    const sans_semibold = try FontFace.init(library, fallback, pixels);
    return .{
        .identity = identity,
        .primary = primary,
        .text = text,
        .symbols = symbols,
        .sans = sans,
        .sans_semibold = sans_semibold,
        .context = .{ .library = library, .options = options, .pixels = pixels },
    };
}

/// Releases the discovered faces and their file bytes before the embedded ones.
/// Example: `fonts.deinit(allocator);`
pub fn deinit(fonts: *FontSet, allocator: std.mem.Allocator) void {
    fonts.pool.deinit(allocator);
    fonts.sans_semibold.deinit();
    fonts.sans.deinit();
    fonts.symbols.deinit();
    if (fonts.text) |*face| {
        face.deinit();
    }

    fonts.primary.deinit();
}

/// Prefers the requested face whenever it covers the whole grapheme, then the
/// terminal chain: configured font, embedded text font, symbols, discovered
/// faces in discovery order. Reads only resident faces and allocates nothing.
/// Example: `const id = fonts.source("\u{f07b}", .sans);`
pub fn source(fonts: *const FontSet, text: []const u8, preferred: Id) Id {
    if (preferred != .primary and fonts.borrow(preferred).covers(text)) {
        return preferred;
    }

    if (fonts.primary.covers(text)) {
        return .primary;
    }

    if (fonts.text) |*face_value| {
        if (face_value.covers(text)) {
            return .text;
        }
    }

    if (fonts.symbols.covers(text)) {
        return .symbols;
    }

    return if (fonts.pool.covering(text)) |slot| Id.fallback(slot) else .primary;
}

/// Asks the platform for an installed face covering a grapheme the chain
/// lacks, loads it into the pool and answers whether one joined. Cold path
/// only: one native lookup and at most one file read per new grapheme;
/// misses, full pools and unusable files are remembered so the next cold
/// shaping of the same grapheme asks nothing.
/// Example: `if (fonts.discover(allocator, "\u{23f5}")) { ... }`
pub fn discover(fonts: *FontSet, allocator: std.mem.Allocator, text: []const u8) bool {
    if (fonts.context.options.io == null or fonts.source(text, .primary) != .primary or fonts.primary.covers(text)) {
        return false;
    }

    if (fonts.misses.contains(text)) {
        return false;
    }

    var query: [max_query_bytes:0]u8 = undefined;
    const significant = significantBytes(text, &query) orelse {
        fonts.misses.remember(text);
        return false;
    };
    if (significant.len == 0 or fonts.pool.full()) {
        fonts.misses.remember(text);
        return false;
    }

    var match: FontMatch = .{};
    fonts.lookups += 1;
    if (fonts.lookup(significant.ptr, &match) != 0 or fonts.pool.find(match) != null) {
        fonts.misses.remember(text);
        return false;
    }

    var face = FallbackFace.init(allocator, fonts.context, match) catch {
        fonts.misses.remember(text);
        return false;
    };
    if (!face.face.covers(text)) {
        face.deinit(allocator);
        fonts.misses.remember(text);
        return false;
    }

    _ = fonts.addFallback(face).?;
    return true;
}

/// Takes a discovered face into the append-only pool and invalidates resolution caches.
/// The caller retains the face when the pool is full. At most eight additions occur
/// during one set's lifetime, so the revision cannot wrap.
/// Example: `const slot = fonts.addFallback(face) orelse return error.FallbackPoolFull;`
pub fn addFallback(fonts: *FontSet, face: FallbackFace) ?u3 {
    const slot = fonts.pool.add(face) orelse return null;
    fonts.revision += 1;
    return slot;
}

pub fn get(fonts: *FontSet, id: Id) *FontFace {
    return switch (id) {
        .primary => &fonts.primary,
        .text => &fonts.text.?,
        .symbols => &fonts.symbols,
        .sans => &fonts.sans,
        .sans_semibold => &fonts.sans_semibold,
        else => fonts.pool.get(id.fallbackSlot().?),
    };
}

fn borrow(fonts: *const FontSet, id: Id) *const FontFace {
    return switch (id) {
        .primary => &fonts.primary,
        .text => &fonts.text.?,
        .symbols => &fonts.symbols,
        .sans => &fonts.sans,
        .sans_semibold => &fonts.sans_semibold,
        else => &fonts.pool.faces[id.fallbackSlot().?].?.face,
    };
}

fn allocateIdentity(counter: *std.atomic.Value(u64)) !u64 {
    var candidate = counter.load(.monotonic);
    while (candidate != std.math.maxInt(u64)) {
        if (counter.cmpxchgWeak(candidate, candidate + 1, .monotonic, .monotonic)) |observed| {
            candidate = observed;
        } else {
            return candidate;
        }
    }

    return error.FontSetIdentityExhausted;
}

// The codepoints `FontFace.covers` tests, NUL-terminated for the port; null
// when the grapheme does not fit the query.
fn significantBytes(text: []const u8, query: *[max_query_bytes:0]u8) ?[:0]const u8 {
    var len: usize = 0;
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iterator.nextCodepointSlice()) |slice| {
        const codepoint = std.unicode.utf8Decode(slice) catch return null;
        if (codepoint == 0x200c or codepoint == 0x200d or
            (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
            (codepoint >= 0xe0100 and codepoint <= 0xe01ef))
        {
            continue;
        }

        if (len + slice.len > max_query_bytes) {
            return null;
        }

        @memcpy(query[len..][0..slice.len], slice);
        len += slice.len;
    }

    query[len] = 0;
    return query[0..len :0];
}

test "font set identity exhaustion never wraps or reuses a retired identity" {
    var counter: std.atomic.Value(u64) = .init(std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, try allocateIdentity(&counter));
    try std.testing.expectError(error.FontSetIdentityExhausted, allocateIdentity(&counter));
    try std.testing.expectError(error.FontSetIdentityExhausted, allocateIdentity(&counter));
    try std.testing.expectEqual(std.math.maxInt(u64), counter.load(.monotonic));
}
