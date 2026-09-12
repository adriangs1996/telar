//! Configured sidebar renderer and its resolution against host graphics support.

const std = @import("std");
const Support = @import("../environment/environment.zig").Support;

pub const SidebarRendering = enum {
    automatic,
    cells,
    kitty_hybrid,
    kitty_full,

    pub fn parse(name: []const u8) !SidebarRendering {
        if (std.ascii.eqlIgnoreCase(name, "automatic") or std.ascii.eqlIgnoreCase(name, "auto")) {
            return .automatic;
        }
        if (std.ascii.eqlIgnoreCase(name, "cells")) {
            return .cells;
        }
        if (std.ascii.eqlIgnoreCase(name, "kitty-hybrid")) {
            return .kitty_hybrid;
        }
        if (std.ascii.eqlIgnoreCase(name, "kitty-full")) {
            return .kitty_full;
        }
        return error.UnknownSidebarRenderer;
    }

    pub fn resolve(value: SidebarRendering, support: Support) !ResolvedSidebarRendering {
        return switch (value) {
            .automatic => if (support == .supported) .kitty_hybrid else .cells,
            .cells => .cells,
            .kitty_hybrid => if (support == .supported)
                .kitty_hybrid
            else if (support == .unknown)
                .cells
            else
                error.KittyGraphicsUnsupported,
            .kitty_full => if (support == .supported)
                .kitty_full
            else if (support == .unknown)
                .cells
            else
                error.KittyGraphicsUnsupported,
        };
    }
};

pub const ResolvedSidebarRendering = enum { cells, kitty_hybrid, kitty_full };

test "automatic sidebar renderer falls back while capability is absent" {
    try std.testing.expectEqual(ResolvedSidebarRendering.cells, try SidebarRendering.automatic.resolve(.unknown));
    try std.testing.expectEqual(ResolvedSidebarRendering.cells, try SidebarRendering.automatic.resolve(.unsupported));
    try std.testing.expectEqual(ResolvedSidebarRendering.kitty_hybrid, try SidebarRendering.automatic.resolve(.supported));
    try std.testing.expectError(error.KittyGraphicsUnsupported, SidebarRendering.kitty_hybrid.resolve(.unsupported));
}
