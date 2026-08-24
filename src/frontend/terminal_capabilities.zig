//! Exterior-terminal capability negotiation and renderer policy.

const std = @import("std");
const term = @import("term.zig");

pub const query_image_id: u32 = 31;
pub const timeout_ns: u64 = 250 * std.time.ns_per_ms;
pub const query =
    "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\" ++
    "\x1b[14t\x1b[16t\x1b[?1016$p\x1b[c";

pub const Support = enum { unknown, unsupported, supported };

pub const TerminalCapabilities = struct {
    kitty_graphics: Support = .unknown,
    window_width_px: u32 = 0,
    window_height_px: u32 = 0,
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    mouse_pixels: Support = .unknown,

    pub fn observe(capabilities: *TerminalCapabilities, response: term.Event.TerminalResponse) bool {
        const before = capabilities.*;
        switch (response) {
            .kitty_graphics => |reply| {
                if (reply.image_id == query_image_id)
                    capabilities.kitty_graphics = if (reply.supported) .supported else .unsupported;
            },
            .window_pixels => |size| {
                capabilities.window_width_px = size.width;
                capabilities.window_height_px = size.height;
            },
            .cell_pixels => |size| {
                capabilities.cell_width_px = size.width;
                capabilities.cell_height_px = size.height;
            },
            .mouse_pixels => |reply| {
                capabilities.mouse_pixels = if (reply.supported) .supported else .unsupported;
            },
            // DA only flushes a multiplexer response path; it does not prove
            // that an earlier APC probe was rejected.
            .primary_device_attributes => {},
        }
        return !std.meta.eql(before, capabilities.*);
    }

    pub fn expire(capabilities: *TerminalCapabilities) bool {
        var changed = false;
        if (capabilities.kitty_graphics == .unknown) {
            capabilities.kitty_graphics = .unsupported;
            changed = true;
        }
        if (capabilities.mouse_pixels == .unknown) {
            capabilities.mouse_pixels = .unsupported;
            changed = true;
        }
        return changed;
    }

    pub fn cellSize(capabilities: *const TerminalCapabilities, cols: u16, rows: u16) struct {
        width: u16,
        height: u16,
    } {
        const width = if (capabilities.cell_width_px != 0)
            capabilities.cell_width_px
        else if (cols != 0)
            capabilities.window_width_px / cols
        else
            0;
        const height = if (capabilities.cell_height_px != 0)
            capabilities.cell_height_px
        else if (rows != 0)
            capabilities.window_height_px / rows
        else
            0;
        return .{
            .width = std.math.cast(u16, width) orelse 0,
            .height = std.math.cast(u16, height) orelse 0,
        };
    }
};

pub const SidebarRendering = enum {
    automatic,
    cells,
    kitty_hybrid,
    kitty_full,

    pub fn parse(name: []const u8) !SidebarRendering {
        if (std.ascii.eqlIgnoreCase(name, "automatic") or std.ascii.eqlIgnoreCase(name, "auto")) return .automatic;
        if (std.ascii.eqlIgnoreCase(name, "cells")) return .cells;
        if (std.ascii.eqlIgnoreCase(name, "kitty-hybrid")) return .kitty_hybrid;
        if (std.ascii.eqlIgnoreCase(name, "kitty-full")) return .kitty_full;
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
