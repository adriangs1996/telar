const objc = @import("objc");
const native_input = @import("../input/NativeInput.zig");
const input = @import("../input/Input.zig");

const HostState = @import("../HostState.zig");
const ClipboardResult = @import("../input/ClipboardResult.zig");
const HostRequest = @typeInfo(@FieldType(HostState, "request")).optional.child;
const Status = ClipboardResult.Status;

const RequestKind = enum(u32) {
    read = 1,
    write = 2,
};

const NativeKind = enum(u32) {
    clipboard = 9,
};

const Encoding = enum(usize) {
    utf8 = 4,
};

const Range = extern struct {
    location: usize,
    length: usize,
};

extern "c" var NSPasteboardTypeString: objc.c.id;

const Clipboard = @This();
// SAFETY: read encodes the pasteboard string before returning a completion with its byte length; failures expose no byte payload.
bytes: [input.Input.max_text_bytes]u8 = undefined,
completion: ?native_input.NativeInput = null,

/// The window calls this outside native input dispatch, on the main thread.
/// Keep one completion until admission; queue pressure must never repeat a write.
pub fn poll(self: *Clipboard, host: *HostState) void {
    if (self.completion == null) {
        const request = host.request orelse return;
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const board = objc.getClass("NSPasteboard").?.msgSend(objc.Object, "generalPasteboard", .{});
        self.completion = self.execute(board, request);
        host.request = null;
    }

    if (host.receive(@bitCast(self.completion.?))) {
        self.completion = null;
    }
}

// AppKit materializes the system string. Bound its UTF-8 representation before
// encoding directly into our retained storage; no NSData or C service is needed.
fn execute(self: *Clipboard, board: objc.Object, request: HostRequest) native_input.NativeInput {
    var result: native_input.NativeInput = .{
        .kind = @intFromEnum(NativeKind.clipboard),
        .request_id = request.request_id,
        .target_id = request.target_id,
        .generation = request.generation,
    };
    const status: Status = if (request.len > self.bytes.len or (request.len != 0 and request.text == null))
        .too_large
    else switch (request.kind) {
        @intFromEnum(RequestKind.read) => self.read(board, &result),
        @intFromEnum(RequestKind.write) => write(board, request),
        else => .unavailable,
    };
    result.code = @intFromEnum(status);
    return result;
}

fn read(self: *Clipboard, board: objc.Object, result: *native_input.NativeInput) Status {
    const raw = board.msgSend(objc.c.id, "stringForType:", .{NSPasteboardTypeString});
    if (raw == null) {
        return .unavailable;
    }

    const text = objc.Object.fromId(raw);
    if (text.msgSend(usize, "lengthOfBytesUsingEncoding:", .{@intFromEnum(Encoding.utf8)}) > self.bytes.len) {
        return .too_large;
    }

    var written: usize = 0;
    const range: Range = .{ .location = 0, .length = text.msgSend(usize, "length", .{}) };
    if (!text.msgSend(bool, "getBytes:maxLength:usedLength:encoding:options:range:remainingRange:", .{
        &self.bytes,
        self.bytes.len,
        &written,
        @intFromEnum(Encoding.utf8),
        @as(usize, 0),
        range,
        @as(?*Range, null),
    })) {
        return .unavailable;
    }

    result.text = &self.bytes;
    result.len = written;
    return .success;
}

fn write(board: objc.Object, request: HostRequest) Status {
    const allocated = objc.getClass("NSString").?.msgSend(objc.Object, "alloc", .{});
    const raw = allocated.msgSend(objc.c.id, "initWithBytes:length:encoding:", .{ request.text, request.len, @intFromEnum(Encoding.utf8) });
    if (raw == null) {
        return .unavailable;
    }

    const text = objc.Object.fromId(raw);
    defer text.release();
    _ = board.msgSend(isize, "clearContents", .{});
    return if (board.msgSend(bool, "setString:forType:", .{ text, NSPasteboardTypeString })) .success else .unavailable;
}
