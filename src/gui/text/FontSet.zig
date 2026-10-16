//! Fixed fallback order for resident faces. Installed-font discovery never
//! runs on the render thread: a cold shaping only queues the grapheme, a
//! background lookup answers it, and the answer joins the set between frames.
const font_id = @import("font_id.zig");
const std = @import("std");
const freetype = @import("freetype");
const assets = @import("assets");
const FontFace = @import("FontFace.zig");
const FaceContext = @import("FaceContext.zig");
const FallbackFace = @import("FallbackFace.zig");
const FallbackPool = @import("FallbackPool.zig");
const GraphemeMisses = @import("GraphemeMisses.zig");
const AtlasOptions = @import("AtlasOptions.zig");
const LigatureCoverage = @import("LigatureCoverage.zig");
const FontQuery = @import("FontQuery.zig");
const FontCandidate = @import("FontCandidate.zig");
const kitty_protocol = @import("kitty_protocol");
const FontSet = @This();

var next_identity: std.atomic.Value(u64) = .init(1);

/// Graphemes waiting for a lookup. A cold frame of unknown scripts queues
/// at most this many; the rest ask again once the queue drains.
pub const pending_capacity = 16;
/// Times in a row a drained queue retires the shaping cache so turned-away
/// graphemes ask again, with no face joining in between. Bounds the work a
/// screen of distinct uncovered graphemes (binary output, say) can cause;
/// a face joining restores it.
pub const max_retries = 4;

/// Never reused, including when a replacement set occupies the same address.
identity: u64,
/// Changes when the resident fallback order changes, and when graphemes the
/// full queue turned away must be shaped (and so requested) again.
revision: u64 = 0,
primary: FontFace,
/// What the primary face's ligature lookups join across terminal cells.
ligatures: LigatureCoverage,
text: ?FontFace,
symbols: FontFace,
sans: FontFace,
sans_semibold: FontFace,
context: FaceContext,
pool: FallbackPool = .{},
misses: GraphemeMisses = .{},
// SAFETY: request writes each query before increasing pending_count; reads stay within the live ring range.
pending: [pending_capacity]FontQuery = undefined,
pending_head: u8 = 0,
pending_count: u8 = 0,
/// The query a background lookup is answering now.
in_flight: ?FontQuery = null,
/// A full queue turned a grapheme away since the queue last drained.
turned_away: bool = false,
/// Retries spent since a face last joined; see `max_retries`.
retries: u8 = 0,

/// Loads the configured face plus embedded text, symbols and the two chrome
/// sans weights, sharing one page. Discovered faces join later.
/// Example: `var fonts = try FontSet.init(library, options, pixels);`
pub fn init(library: freetype.c.FT_Library, options: AtlasOptions, pixels: []u8) !FontSet {
    const identity = try allocateIdentity(&next_identity);
    var primary = try FontFace.init(library, options, pixels);
    errdefer primary.deinit();
    var ligatures = try LigatureCoverage.init(primary.face, primary.shaping_font);
    errdefer ligatures.deinit();
    var fallback = options;
    fallback.face_index = 0;
    fallback.postscript = "";
    fallback.variation = .{};
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
        .ligatures = ligatures,
        .text = text,
        .symbols = symbols,
        .sans = sans,
        .sans_semibold = sans_semibold,
        .context = .{ .library = library, .options = options, .pixels = pixels },
    };
}

/// Releases the discovered faces and their file bytes before the embedded ones.
/// Example: `fonts.deinit(allocator);`
pub fn deinit(self: *FontSet, allocator: std.mem.Allocator) void {
    self.pool.deinit(allocator);
    self.sans_semibold.deinit();
    self.sans.deinit();
    self.symbols.deinit();
    if (self.text) |*face| {
        face.deinit();
    }

    self.ligatures.deinit();
    self.primary.deinit();
}

/// Prefers the requested face whenever it covers the whole grapheme, then the
/// terminal chain: configured font, embedded text font, symbols, discovered
/// faces in discovery order. Reads only resident faces and allocates nothing.
/// Example: `const id = fonts.source("\u{f07b}", .sans);`
pub fn source(self: *const FontSet, text: []const u8, preferred: font_id.Id) font_id.Id {
    if (preferred != .primary and self.borrow(preferred).covers(text)) {
        return preferred;
    }

    if (self.primary.covers(text)) {
        return .primary;
    }

    if (self.text) |*face_value| {
        if (face_value.covers(text)) {
            return .text;
        }
    }

    if (self.symbols.covers(text)) {
        return .symbols;
    }

    return if (self.pool.covering(text)) |slot| font_id.Id.fallback(slot) else .primary;
}

/// Queues a grapheme no resident face covers for a background lookup.
/// Cold path only and allocation free: misses, duplicates, a full pool and
/// Kitty Unicode placeholders, which are never glyphs, ask nothing.
/// Example: `fonts.request("\u{23f5}");`
pub fn request(self: *FontSet, text: []const u8) void {
    if (self.context.options.io == null or self.source(text, .primary) != .primary or self.primary.covers(text)) {
        return;
    }

    if (kitty_protocol.unicode_placeholder.starts(text) or self.misses.contains(text) or self.queued(text)) {
        return;
    }

    var buffer: [FontQuery.max_bytes:0]u8 = undefined;
    const significant = significantBytes(text, &buffer) orelse {
        self.misses.remember(text);
        return;
    };
    if (significant.len == 0 or self.pool.full()) {
        self.misses.remember(text);
        return;
    }

    const query = FontQuery.init(self.identity, text, significant) orelse {
        self.misses.remember(text);
        return;
    };
    if (self.pending_count == pending_capacity) {
        self.turned_away = true;
        return;
    }

    self.pending[(self.pending_head + self.pending_count) % pending_capacity] = query;
    self.pending_count += 1;
}

/// Hands the oldest queued grapheme to a background lookup; null while one
/// is in flight or nothing waits.
/// Example: `const query = fonts.takeQuery() orelse return;`
pub fn takeQuery(self: *FontSet) ?FontQuery {
    if (self.in_flight != null or self.pending_count == 0) {
        return null;
    }

    const query = self.pending[self.pending_head];
    self.pending_head = @intCast((self.pending_head + 1) % pending_capacity);
    self.pending_count -= 1;
    self.in_flight = query;
    return query;
}

/// Takes the background answer for the query in flight: a face that covers
/// the grapheme joins the pool, anything else is remembered as a miss. Owns
/// `candidate.bytes` either way. Returns whether the resident order changed,
/// so retained geometry drawn with the replacement glyph must repaint.
/// Example: `if (fonts.adopt(allocator, query, candidate)) retained.invalidate();`
pub fn adopt(self: *FontSet, allocator: std.mem.Allocator, query: *const FontQuery, candidate: ?FontCandidate) bool {
    const previous = self.revision;
    if (self.in_flight) |*current| {
        if (current.names(query.text())) {
            self.in_flight = null;
        }
    }

    self.join(allocator, query.text(), candidate);
    if (self.revision != previous) {
        self.retries = 0;
    }

    if (self.turned_away and self.pending_count == 0 and self.in_flight == null) {
        // Graphemes the full queue refused were cached as shaped with the
        // replacement glyph; retiring that cache lets them ask again.
        self.turned_away = false;
        if (self.retries < max_retries) {
            self.retries += 1;
            self.revision += 1;
        }
    }

    return self.revision != previous;
}

fn join(self: *FontSet, allocator: std.mem.Allocator, text: []const u8, candidate: ?FontCandidate) void {
    const found = candidate orelse {
        self.misses.remember(text);
        return;
    };
    if (self.pool.full() or self.pool.find(found.match) != null) {
        allocator.free(found.bytes);
        self.misses.remember(text);
        return;
    }

    var face = FallbackFace.init(self.context, found.match, found.bytes) catch {
        allocator.free(found.bytes);
        self.misses.remember(text);
        return;
    };
    if (!face.face.covers(text)) {
        face.deinit(allocator);
        self.misses.remember(text);
        return;
    }

    _ = self.addFallback(face).?;
}

fn queued(self: *const FontSet, text: []const u8) bool {
    if (self.in_flight) |*current| {
        if (current.names(text)) {
            return true;
        }
    }

    for (0..self.pending_count) |offset| {
        if (self.pending[(self.pending_head + offset) % pending_capacity].names(text)) {
            return true;
        }
    }

    return false;
}

/// Takes a discovered face into the append-only pool and invalidates resolution caches.
/// The caller retains the face when the pool is full. At most eight additions occur
/// during one set's lifetime, so the revision cannot wrap.
/// Example: `const slot = fonts.addFallback(face) orelse return error.FallbackPoolFull;`
pub fn addFallback(self: *FontSet, face: FallbackFace) ?u3 {
    const slot = self.pool.add(face) orelse return null;
    self.revision += 1;
    return slot;
}

pub fn get(self: *FontSet, id: font_id.Id) *FontFace {
    return switch (id) {
        .primary => &self.primary,
        .text => &self.text.?,
        .symbols => &self.symbols,
        .sans => &self.sans,
        .sans_semibold => &self.sans_semibold,
        else => self.pool.get(id.fallbackSlot().?),
    };
}

fn borrow(self: *const FontSet, id: font_id.Id) *const FontFace {
    return switch (id) {
        .primary => &self.primary,
        .text => &self.text.?,
        .symbols => &self.symbols,
        .sans => &self.sans,
        .sans_semibold => &self.sans_semibold,
        else => &self.pool.faces[id.fallbackSlot().?].?.face,
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
fn significantBytes(text: []const u8, query: *[FontQuery.max_bytes:0]u8) ?[:0]const u8 {
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

        if (len + slice.len > FontQuery.max_bytes) {
            return null;
        }

        @memcpy(query[len..][0..slice.len], slice);
        len += slice.len;
    }

    query[len] = 0;
    return query[0..len :0];
}
