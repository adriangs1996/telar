const std = @import("std");
const Key = @import("key.zig").Key;

pub fn parseKey(text: []const u8) !Key {
    if (text.len == 0) {
        return error.EmptyKey;
    }

    var mods: Key.Mods = .{};
    var code_text: ?[]const u8 = null;
    var parts = std.mem.splitScalar(u8, text, '+');
    while (parts.next()) |part| {
        if (part.len == 0) {
            return error.EmptyKeyPart;
        }
        if (code_text != null) {
            return error.ModifierAfterKey;
        }

        if (eqlAscii(part, "ctrl") or eqlAscii(part, "control")) {
            if (mods.ctrl) {
                return error.DuplicateModifier;
            }
            mods.ctrl = true;
        } else if (eqlAscii(part, "alt")) {
            if (mods.alt) {
                return error.DuplicateModifier;
            }
            mods.alt = true;
        } else if (eqlAscii(part, "shift")) {
            if (mods.shift) {
                return error.DuplicateModifier;
            }
            mods.shift = true;
        } else {
            code_text = part;
        }
    }

    const name = code_text orelse return error.MissingKey;
    var code = try parseCode(name);

    // Legacy terminals report Shift+Tab as its own CSI sequence and do not set
    // a modifier bit. Store the form the input parser emits.
    if (code == .tab and mods.shift and !mods.ctrl and !mods.alt) {
        code = .back_tab;
        mods.shift = false;
    }

    // Ctrl letters arrive as C0 bytes and therefore lose their case. Treat
    // `ctrl+B` and `ctrl+b` as the same configuration value.
    if (mods.ctrl) {
        switch (code) {
            .char => |*char| {
                if (char.len == 1 and std.ascii.isUpper(char.bytes[0])) {
                    char.bytes[0] = std.ascii.toLower(char.bytes[0]);
                }
            },
            else => {},
        }
    }

    // Legacy terminal input carries the resulting printable character, not a
    // Shift bit. Canonicalize the combinations whose result is independent of
    // keyboard layout and reject the rest instead of accepting a dead binding.
    if (mods.shift) {
        switch (code) {
            .char => |*char| {
                if (mods.ctrl) {
                    return error.UnrepresentableKey;
                }
                if (char.len == 1 and std.ascii.isAlphabetic(char.bytes[0])) {
                    char.bytes[0] = std.ascii.toUpper(char.bytes[0]);
                    mods.shift = false;
                } else if (char.len == 1 and char.bytes[0] == ' ') {
                    mods.shift = false;
                } else {
                    return error.UnrepresentableKey;
                }
            },
            else => {},
        }
    }

    return .{ .code = code, .mods = mods };
}

fn parseCode(text: []const u8) !Key.Code {
    if (eqlAscii(text, "up")) {
        return .up;
    }
    if (eqlAscii(text, "down")) {
        return .down;
    }
    if (eqlAscii(text, "left")) {
        return .left;
    }
    if (eqlAscii(text, "right")) {
        return .right;
    }
    if (eqlAscii(text, "home")) {
        return .home;
    }
    if (eqlAscii(text, "end")) {
        return .end;
    }
    if (eqlAscii(text, "delete") or eqlAscii(text, "del")) {
        return .delete;
    }
    if (eqlAscii(text, "pageup") or eqlAscii(text, "page-up")) {
        return .page_up;
    }
    if (eqlAscii(text, "pagedown") or eqlAscii(text, "page-down")) {
        return .page_down;
    }
    if (eqlAscii(text, "enter") or eqlAscii(text, "return")) {
        return .enter;
    }
    if (eqlAscii(text, "escape") or eqlAscii(text, "esc")) {
        return .escape;
    }
    if (eqlAscii(text, "backspace")) {
        return .backspace;
    }
    if (eqlAscii(text, "tab")) {
        return .tab;
    }
    if (eqlAscii(text, "backtab")) {
        return .back_tab;
    }
    if (eqlAscii(text, "space")) {
        return .{ .char = .init(" ") };
    }
    if (eqlAscii(text, "plus")) {
        return .{ .char = .init("+") };
    }

    const sequence_len = std.unicode.utf8ByteSequenceLength(text[0]) catch
        return error.InvalidUtf8;
    if (sequence_len != text.len) {
        return error.KeyMustBeOneCodepoint;
    }
    _ = std.unicode.utf8Decode(text) catch return error.InvalidUtf8;
    return .{ .char = .init(text) };
}

fn eqlAscii(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
