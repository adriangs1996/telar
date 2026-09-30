//! How far the interactive terminal's cursor moves after a Kitty graphics
//! command. That terminal ignores graphics APCs, which the media terminal
//! executes, so without this the text a child writes after an image lands
//! on top of it. Kitty and Ghostty move the cursor past a placement unless
//! it asked `C=1`, is virtual (`U=1`) or relative (`P`).
//!
//! Commands follow Ghostty's `graphics_exec`: while a chunked transmission
//! loads, any further transmission continues it (`m` other than 0 means more
//! chunks), a delete aborts it, and a put or query runs on its own. A put
//! needs an image id or number whose image this pane transmitted, or it
//! fails with ENOENT and the cursor stays; `i` and `I` together are EINVAL.
//!
//! Only control data and the first payload bytes are read: sizes come from
//! `s`/`v`, from a direct PNG's IHDR, or, for `a=p`, from the sizes this
//! pane transmitted and has not deleted. Nothing is decoded beyond 24 bytes
//! and nothing allocates. What this cannot see - an image the media
//! terminal failed to load, or evicted for its quota - still moves the
//! cursor here while Ghostty's stays.
const std = @import("std");
const core = @import("telar-core");
const kitty_protocol = @import("kitty_protocol");
const vtscan = @import("vtscan");
const KittyCursor = @This();

const sizes_capacity = core.max_images_per_pane;
const png_signature = "\x89PNG\r\n\x1a\n";
const png_header_bytes = 24;
const png_width_offset = 16;
const png_height_offset = 20;
const png_chunk_type_offset = 12;

/// A chunked command's first header, applied when its last chunk arrives.
pending: ?Header = null,
/// Image sizes by child image id or number, replaced round robin when full.
sizes: [sizes_capacity]ImageSize = @splat(.{}),
next_size: usize = 0,

/// The `f` values a transmission may carry.
const PixelFormat = enum(u32) {
    rgb = 24,
    rgba = 32,
    png = 100,
    _,
};

const ImageSize = struct {
    image_id: u32 = 0,
    image_number: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

const Header = struct {
    action: u8 = 't',
    image_id: u32 = 0,
    image_number: u32 = 0,
    /// The `d` key of a delete.
    target: u8 = 'a',
    width: u32 = 0,
    height: u32 = 0,
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    offset_x: u32 = 0,
    offset_y: u32 = 0,
    /// `C=1`, `U=1` or a parent placement: the cursor stays.
    stays: bool = false,
    more: bool = false,
};

/// Takes one command the scanner saw end and returns the cells to move the
/// cursor past, or null when it stays.
///
/// ```zig
/// if (pane.kitty_cursor.observe(command, cell_width, cell_height)) |cells| advance(cells);
/// ```
pub fn observe(self: *KittyCursor, command: vtscan.KittyCommand, cell_width: u32, cell_height: u32) ?kitty_protocol.DisplayCells {
    const header = parse(command) orelse return null;
    if (command.truncated or (header.image_id != 0 and header.image_number != 0)) {
        return null;
    }

    const transmits = header.action == 't' or header.action == 'T';
    if (self.pending) |first| {
        if (transmits) {
            // A continuation: the first chunk's header decides.
            if (header.more) {
                return null;
            }

            self.pending = null;
            return self.execute(first, cell_width, cell_height);
        }

        if (header.action == 'd') {
            self.pending = null;
        }
    } else if (transmits and header.more) {
        self.pending = header;
        return null;
    }

    return self.execute(header, cell_width, cell_height);
}

fn execute(self: *KittyCursor, header: Header, cell_width: u32, cell_height: u32) ?kitty_protocol.DisplayCells {
    const transmits = header.action == 't' or header.action == 'T';
    if (transmits and header.width != 0 and header.height != 0 and
        (header.image_id != 0 or header.image_number != 0))
    {
        self.remember(header);
    }

    if (header.action == 'd') {
        self.forget(header);
        return null;
    }

    if ((header.action != 'T' and header.action != 'p') or header.stays) {
        return null;
    }

    var width = header.width;
    var height = header.height;
    if (header.action == 'p') {
        // ENOENT without an image this pane transmitted: the cursor stays.
        const known = self.find(header) orelse return null;
        width = known.width;
        height = known.height;
    }

    if ((width == 0 or height == 0) and (header.columns == 0 or header.rows == 0)) {
        return null;
    }

    // The source rectangle intersected with the image, as Ghostty does.
    const source_x = @min(header.source_x, width);
    const source_y = @min(header.source_y, height);
    const covered = kitty_protocol.displayCells(.{
        .source_width = @min(if (header.source_width != 0) header.source_width else width, width - source_x),
        .source_height = @min(if (header.source_height != 0) header.source_height else height, height - source_y),
        .columns = header.columns,
        .rows = header.rows,
        .offset_x = header.offset_x,
        .offset_y = header.offset_y,
        .cell_width = cell_width,
        .cell_height = cell_height,
    });

    if (covered.columns == 0 or covered.rows == 0) {
        return null;
    }

    return covered;
}

fn remember(self: *KittyCursor, header: Header) void {
    const size: ImageSize = .{
        .image_id = header.image_id,
        .image_number = header.image_number,
        .width = header.width,
        .height = header.height,
    };
    if (self.slotOf(header)) |slot| {
        self.sizes[slot] = size;
        return;
    }

    self.sizes[self.next_size] = size;
    self.next_size = (self.next_size + 1) % self.sizes.len;
}

// The deletes that free an image's data: `d=I` by id, `d=N` by number,
// `d=A` everything. Lowercase ones keep the image for later puts.
fn forget(self: *KittyCursor, header: Header) void {
    switch (header.target) {
        'A' => self.sizes = @splat(.{}),
        'I', 'N' => if (self.slotOf(header)) |slot| {
            self.sizes[slot] = .{};
        },
        else => {},
    }
}

fn find(self: *const KittyCursor, header: Header) ?ImageSize {
    const slot = self.slotOf(header) orelse return null;
    return self.sizes[slot];
}

// By id when the command names one, else by number; the newest image with a
// number wins, as Ghostty's `imageByNumber` does.
fn slotOf(self: *const KittyCursor, header: Header) ?usize {
    for (self.sizes, 0..) |size, slot| {
        if (header.image_id != 0 and size.image_id == header.image_id) {
            return slot;
        }

        if (header.image_id == 0 and header.image_number != 0 and size.image_number == header.image_number) {
            return slot;
        }
    }

    return null;
}

// Reads the fields a placement's size depends on; null for malformed data.
fn parse(command: vtscan.KittyCommand) ?Header {
    var header: Header = .{};
    var format: PixelFormat = .rgba;
    var direct = true;
    var compressed = false;
    var fields = kitty_protocol.ControlFields.init(command.control);
    while (fields.next() catch return null) |field| {
        const number = std.fmt.parseUnsigned(u32, field.value, 10) catch 0;
        switch (field.key) {
            'a' => header.action = field.value[0],
            'i' => header.image_id = number,
            'I' => header.image_number = number,
            'd' => header.target = field.value[0],
            'f' => format = @enumFromInt(number),
            's' => header.width = number,
            'v' => header.height = number,
            'x' => header.source_x = number,
            'y' => header.source_y = number,
            'w' => header.source_width = number,
            'h' => header.source_height = number,
            'c' => header.columns = number,
            'r' => header.rows = number,
            'X' => header.offset_x = number,
            'Y' => header.offset_y = number,
            'C' => header.stays = header.stays or number == 1,
            'U' => header.stays = header.stays or number == 1,
            'P' => header.stays = true,
            'm' => header.more = number != 0,
            't' => direct = field.value[0] == 'd',
            'o' => compressed = true,
            else => {},
        }
    }

    if (format == .png) {
        header.width = 0;
        header.height = 0;
        if (direct and !compressed) {
            if (pngSize(command.payload)) |size| {
                header.width = size[0];
                header.height = size[1];
            }
        }
    }

    return header;
}

// Width and height from the IHDR at the start of a base64 PNG.
fn pngSize(encoded: []const u8) ?[2]u32 {
    const decoder = std.base64.standard.Decoder;
    const needed = std.base64.standard.Encoder.calcSize(png_header_bytes);
    if (encoded.len < needed) {
        return null;
    }

    var bytes: [png_header_bytes]u8 = undefined;
    decoder.decode(&bytes, encoded[0..needed]) catch return null;
    if (!std.mem.eql(u8, bytes[0..png_signature.len], png_signature) or
        !std.mem.eql(u8, bytes[png_chunk_type_offset..][0..4], "IHDR"))
    {
        return null;
    }

    return .{
        std.mem.readInt(u32, bytes[png_width_offset..][0..4], .big),
        std.mem.readInt(u32, bytes[png_height_offset..][0..4], .big),
    };
}

fn commandOf(control: []const u8, payload: []const u8) vtscan.KittyCommand {
    return .{
        .end = 0,
        .control = control,
        .payload = payload,
        .truncated = false,
    };
}

test "a raw transmit-and-display moves past its natural size" {
    var cursor: KittyCursor = .{};
    const cells = cursor.observe(commandOf("a=T,f=32,s=100,v=50,i=1", "AAAA"), 10, 20).?;
    try std.testing.expectEqual(kitty_protocol.DisplayCells{ .columns = 10, .rows = 3 }, cells);
}

test "requested cells win and C=1, U=1 and P keep the cursor" {
    var cursor: KittyCursor = .{};
    try std.testing.expectEqual(
        kitty_protocol.DisplayCells{ .columns = 36, .rows = 10 },
        cursor.observe(commandOf("a=T,f=32,s=360,v=200,c=36,r=10,q=2", "AAAA"), 10, 20).?,
    );
    try std.testing.expect(cursor.observe(commandOf("a=T,f=32,s=10,v=10,C=1", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=p,i=1,U=1,c=2,r=2", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=p,i=1,P=4,c=2,r=2", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=t,f=32,s=10,v=10", ""), 10, 20) == null);
}

test "a chunked PNG moves once, at its last chunk, by its IHDR size" {
    var cursor: KittyCursor = .{};
    // 20x40 PNG: signature, IHDR length and type, width 20, height 40.
    const header = png_signature ++ "\x00\x00\x00\x0dIHDR\x00\x00\x00\x14\x00\x00\x00\x28";
    var encoded: [std.base64.standard.Encoder.calcSize(header.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, header);
    try std.testing.expect(cursor.observe(commandOf("a=T,f=100,i=3,m=1", &encoded), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("m=1", "AAAA"), 10, 20) == null);
    try std.testing.expectEqual(
        kitty_protocol.DisplayCells{ .columns = 2, .rows = 2 },
        cursor.observe(commandOf("m=0", "AAAA"), 10, 20).?,
    );

    // A later put of the same image uses the size it transmitted.
    try std.testing.expectEqual(
        kitty_protocol.DisplayCells{ .columns = 2, .rows = 2 },
        cursor.observe(commandOf("a=p,i=3", ""), 10, 20).?,
    );
    try std.testing.expect(cursor.observe(commandOf("a=p,i=4", ""), 10, 20) == null);
}

test "malformed or truncated control data never moves the cursor" {
    var cursor: KittyCursor = .{};
    try std.testing.expect(cursor.observe(commandOf("a=T,bogus", ""), 10, 20) == null);
    var truncated = commandOf("a=T,f=32,s=10,v=10", "");
    truncated.truncated = true;
    try std.testing.expect(cursor.observe(truncated, 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=T,f=32,s=10,v=10", ""), 0, 0) == null);
}

test "a put or query during a chunked upload runs on its own and a delete aborts it" {
    var cursor: KittyCursor = .{};
    try std.testing.expect(cursor.observe(commandOf("a=t,f=32,s=10,v=10,i=1", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=T,f=32,s=100,v=40,i=2,m=1", ""), 10, 20) == null);
    // A put of image 1 in the middle moves by image 1 and keeps the upload.
    try std.testing.expectEqual(
        kitty_protocol.DisplayCells{ .columns = 1, .rows = 1 },
        cursor.observe(commandOf("a=p,i=1", ""), 10, 20).?,
    );
    try std.testing.expect(cursor.observe(commandOf("m=2", "AAAA"), 10, 20) == null);
    try std.testing.expectEqual(
        kitty_protocol.DisplayCells{ .columns = 10, .rows = 2 },
        cursor.observe(commandOf("m=0", "AAAA"), 10, 20).?,
    );

    try std.testing.expect(cursor.observe(commandOf("a=T,f=32,s=100,v=40,i=3,m=1", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=d,d=a", ""), 10, 20) == null);
    // Aborted: the next chunk starts nothing and moves nothing.
    try std.testing.expect(cursor.observe(commandOf("m=0", "AAAA"), 10, 20) == null);
}

test "puts need an image that exists, by id or number, and deletes forget it" {
    var cursor: KittyCursor = .{};
    try std.testing.expect(cursor.observe(commandOf("a=p,c=2,r=2", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=p,i=9,c=2,r=2", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=t,f=32,s=10,v=10,I=4", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=p,I=4", ""), 10, 20) != null);
    try std.testing.expect(cursor.observe(commandOf("a=p,i=1,I=4", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=d,d=N,I=4", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=p,I=4", ""), 10, 20) == null);

    try std.testing.expect(cursor.observe(commandOf("a=t,f=32,s=10,v=10,i=5", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=d,d=i,i=5", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=p,i=5", ""), 10, 20) != null);
    try std.testing.expect(cursor.observe(commandOf("a=d,d=I,i=5", ""), 10, 20) == null);
    try std.testing.expect(cursor.observe(commandOf("a=p,i=5", ""), 10, 20) == null);
}
