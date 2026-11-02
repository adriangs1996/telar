import argparse
import itertools
from pathlib import Path
import random
import re
import struct
import subprocess
import tempfile


cpp_probe = r'''
#include "application/records.hpp"
#include "presentation/sidebar_columns.hpp"
#include "presentation/sidebar_geometry.hpp"
#include "presentation/tab_caption.hpp"
#include "presentation/tab_strip_geometry.hpp"
#include "presentation/workspace_mark.hpp"
#include "presentation/workspace_window.hpp"
#include "presentation/workspace_rail_geometry.hpp"
#include "presentation/window_title.hpp"
#include <array>
#include <bit>
#include <cstdint>
#include <iostream>
#include <string>

static_assert(std::endian::native == std::endian::little);

template <typename Value>
bool read(Value &value) {
  return bool(std::cin.read(reinterpret_cast<char *>(&value), sizeof(value)));
}

void write(std::string_view text) {
  const auto length = static_cast<std::uint32_t>(text.size());
  std::cout.write(reinterpret_cast<const char *>(&length), sizeof(length));
  std::cout.write(text.data(), static_cast<std::streamsize>(text.size()));
}

int main() {
  std::uint8_t kind = 0;
  while (read(kind)) {
    if (kind == 0) {
      std::array<std::uint32_t, 6> lengths{};
      std::array<std::string, 6> fields{};
      for (auto &length : lengths) {
        if (!read(length) || length > 4096) return 1;
      }
      for (std::size_t index = 0; index < fields.size(); ++index) {
        fields[index].resize(lengths[index]);
        if (!std::cin.read(fields[index].data(), lengths[index])) return 1;
      }
      auto title = telar::gui::WindowTitle::render(fields[0], {.workspace=fields[1], .tab=fields[2], .pane_title=fields[3], .hostname=fields[4]});
      title.appendSuffix(fields[5]);
      write(title.view());
    } else if (kind == 1) {
      std::uint32_t host = 0;
      std::int64_t requested = 0;
      if (!read(host) || !read(requested) || host > UINT16_MAX) return 1;
      try {
        const auto width = telar::gui::SidebarColumns::clamp(static_cast<std::uint16_t>(host), requested);
        write({reinterpret_cast<const char *>(&width), sizeof(width)});
      } catch (const std::invalid_argument &error) {
        write(error.what());
      }
    } else if (kind == 2) {
      std::uint32_t length = 0;
      if (!read(length) || length > 4096) return 1;
      std::string name(length, '\0');
      if (!std::cin.read(name.data(), length)) return 1;
      const auto mark = telar::gui::WorkspaceMark::resolve(name);
      constexpr std::array hue_order{telar::gui::PaletteRole::red, telar::gui::PaletteRole::peach, telar::gui::PaletteRole::yellow, telar::gui::PaletteRole::green, telar::gui::PaletteRole::teal, telar::gui::PaletteRole::blue, telar::gui::PaletteRole::mauve};
      std::array<std::uint32_t, 6> result{};
      result[0] = std::find(hue_order.begin(), hue_order.end(), mark.hue) - hue_order.begin();
      result[1] = mark.initial.length;
      for (std::size_t index = 0; index < mark.initial.bytes.size(); ++index) result[index + 2] = static_cast<unsigned char>(mark.initial.bytes[index]);
      write({reinterpret_cast<const char *>(result.data()), sizeof(result)});
    } else if (kind == 3) {
      std::array<std::uint32_t, 3> request{};
      if (!read(request)) return 1;
      const auto window = telar::gui::WorkspaceWindow::centered({.count=request[0], .active=request[1]}, request[2]);
      const std::array<std::uint32_t, 5> result{static_cast<std::uint32_t>(window.first), static_cast<std::uint32_t>(window.count), static_cast<std::uint32_t>(window.total), static_cast<std::uint32_t>(window.previous().value_or(UINT32_MAX)), static_cast<std::uint32_t>(window.next().value_or(UINT32_MAX))};
      write({reinterpret_cast<const char *>(result.data()), sizeof(result)});
    } else if (kind == 4) {
      std::array<float, 5> dimensions{};
      std::array<std::uint32_t, 4> request{};
      if (!read(dimensions) || !read(request)) return 1;
      telar::gui::ChromeMetrics chrome;
      chrome.ratio = dimensions[4];
      chrome.body = request[0];
      chrome.small = request[1];
      const auto regions = telar::gui::SidebarGeometry::measure({dimensions[0], dimensions[1], dimensions[2], dimensions[3]}, chrome, request[2], request[3] != 0);
      const std::array result{regions.machines, regions.projects_header, regions.projects, regions.activity_header, regions.activity};
      static_assert(sizeof(result) == 20 * sizeof(float));
      write({reinterpret_cast<const char *>(result.data()), sizeof(result)});
    } else if (kind == 5) {
      std::array<float, 5> dimensions{};
      std::array<std::uint32_t, 2> request{};
      if (!read(dimensions) || !read(request)) return 1;
      const auto geometry = telar::gui::WorkspaceRailGeometry::measure({dimensions[0], dimensions[1], dimensions[2], dimensions[3]}, dimensions[4], {.count=request[0], .active=request[1]});
      struct Event { std::uint32_t kind, first, end; float x, y, width, height; };
      static_assert(sizeof(Event) == 28);
      std::array<Event, 130> events{};
      std::size_t count = 0;
      const auto append = [&](std::uint32_t event_kind, std::size_t first, std::size_t end, telar::gui::Rect bounds) {
        events[count++] = {event_kind, static_cast<std::uint32_t>(first), static_cast<std::uint32_t>(end), bounds.x, bounds.y, bounds.width, bounds.height};
      };
      if (geometry.window.previous() && !geometry.previous.empty()) append(1, 0, geometry.window.first, geometry.previous);
      auto bounds = geometry.firstMark();
      for (std::size_t position = 0; position < geometry.window.count && !bounds.empty(); ++position) {
        const auto index = geometry.window.first + position;
        append(0, index, index + 1, bounds);
        bounds = geometry.nextMark(bounds);
      }
      if (geometry.window.next() && !geometry.next.empty()) append(2, geometry.window.first + geometry.window.count, geometry.window.total, geometry.next);
      write({reinterpret_cast<const char *>(events.data()), count * sizeof(Event)});
    } else if (kind == 6) {
      std::uint32_t length = 0;
      if (!read(length) || length > 4096) return 1;
      std::string path(length, '\0');
      if (!std::cin.read(path.data(), length)) return 1;
      write(telar::gui::TabCaption::directoryName(path));
    } else if (kind == 7) {
      std::array<std::uint32_t, 4> lengths{};
      std::array<std::string, 4> fields{};
      for (auto &length : lengths) {
        if (!read(length) || length > 4096) return 1;
      }
      for (std::size_t index = 0; index < fields.size(); ++index) {
        fields[index].resize(lengths[index]);
        if (!std::cin.read(fields[index].data(), lengths[index])) return 1;
      }
      telar::gui::TabCaption::Buffer storage;
      write(telar::gui::TabCaption::resolve({.manual=fields[0], .application=fields[1], .directory=fields[2], .session_title=fields[3]}, storage));
    } else if (kind == 8) {
      std::array<std::uint64_t, 3> identities{};
      std::array<std::uint32_t, 2> lengths{};
      std::array<std::string, 2> names{};
      if (!read(identities) || !read(lengths)) return 1;
      for (std::size_t index = 0; index < names.size(); ++index) {
        if (lengths[index] > 4096) return 1;
        names[index].resize(lengths[index]);
        if (!std::cin.read(names[index].data(), lengths[index])) return 1;
      }
      telar::gui::SystemAllocator memory;
      telar::gui::GraphicsBudget budget;
      telar::gui::Tab tab{memory, telar::TabLocation{}};
      tab.foreground_pane = identities[1];
      tab.foreground = names[0];
      telar::gui::Pane pane{memory, identities[2], budget};
      pane.foreground = names[1];
      write(tab.applicationName(identities[0] != 0 ? &pane : nullptr));
    } else if (kind == 9) {
      std::array<float, 2> area{};
      std::array<std::uint32_t, 2> request{};
      if (!read(area) || !read(request) || request[0] == 0 || request[0] > 64 || request[1] >= request[0]) return 1;
      using Geometry = telar::gui::TabStripGeometry;
      std::array<Geometry::Measure, Geometry::maximum_tabs> sizes{};
      for (std::size_t index = 0; index < request[0]; ++index) {
        std::array<float, 3> size{};
        if (!read(size)) return 1;
        sizes[index] = {.caption=size[0], .chip=size[1], .status=size[2]};
      }
      const auto metrics = Geometry::Metrics::scaled(area[1]);
      const auto plan = Geometry::arrange(std::span{sizes}.first(request[0]), request[1], {.width=area[0], .metrics=metrics});
      std::array<std::uint32_t, 135> result{};
      for (std::size_t index = 0; index < Geometry::maximum_tabs; ++index) {
        result[index] = std::bit_cast<std::uint32_t>(plan.widths[index]);
        result[index + Geometry::maximum_tabs] = static_cast<std::uint32_t>(plan.fits[index]);
      }
      result[128] = plan.first;
      result[129] = plan.end;
      result[130] = plan.focus;
      result[131] = plan.count;
      result[132] = plan.hidden();
      result[133] = static_cast<std::uint32_t>(plan.nearestHidden().value_or(UINT32_MAX));
      result[134] = std::bit_cast<std::uint32_t>(plan.footprint(metrics));
      write({reinterpret_cast<const char *>(result.data()), sizeof(result)});
    } else {
      return 1;
    }
  }
  return std::cin.eof() ? 0 : 1;
}
'''

zig_probe = r'''
const std = @import("std");
const original = @import("original");
const WorkspaceWindow = @import("workspace_window");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Layout = gfx.Layout;
const LayoutItem = gfx.Item;
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;

__SIDEBAR__
__CHROME_REFERENCE__
__TAB_REFERENCE__
__STRIP_REFERENCE__

fn readUnsigned(comptime Value: type) !Value {
    var result: Value = 0;
    for (0..@sizeOf(Value)) |index| {
        const byte = getchar();
        if (byte < 0) return error.TruncatedInput;
        result |= @as(Value, @intCast(byte)) << @intCast(index * 8);
    }
    return result;
}

fn write(text: []const u8) !void {
    const length: u32 = @intCast(text.len);
    for (0..@sizeOf(u32)) |index| {
        if (putchar(@intCast((length >> @intCast(index * 8)) & 255)) < 0) return error.WriteFailed;
    }
    for (text) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}

fn windowTitle() !void {
    var lengths: [6]u32 = undefined;
    for (&lengths) |*length| length.* = try readUnsigned(u32);
    var storage: [6][4096]u8 = undefined;
    var fields: [6][]const u8 = undefined;
    for (&storage, lengths, &fields) |*bytes, length, *field| {
        if (length > bytes.len) return error.TooLarge;
        for (bytes[0..length]) |*byte| byte.* = @intCast(getchar());
        field.* = bytes[0..length];
    }
    var output: [original.max_title_bytes]u8 = undefined;
    const rendered = original.render(&output, fields[0], .{.workspace=fields[1], .tab=fields[2], .pane_title=fields[3], .hostname=fields[4]});
    try write(original.appendSuffix(&output, rendered.len, fields[5]));
}

pub fn main() !void {
    while (true) {
        const kind = getchar();
        if (kind < 0) return;
        switch (kind) {
            0 => try windowTitle(),
            1 => {
                const host = std.math.cast(u16, try readUnsigned(u32)) orelse return error.InvalidHost;
                const requested: i64 = @bitCast(try readUnsigned(u64));
                const width = std.math.cast(u16, requested) orelse {
                    try write("InvalidWidth");
                    continue;
                };
                if (width == 0) {
                    try write("InvalidWidth");
                    continue;
                }
                const resolved = clampInteractive(host, width);
                try write(std.mem.asBytes(&resolved));
            },
            2 => {
                const length = try readUnsigned(u32);
                var name: [4096]u8 = undefined;
                if (length > name.len) return error.TooLarge;
                for (name[0..length]) |*byte| byte.* = @intCast(getchar());
                var bytes: [4]u8 = @splat(0);
                const letter = initial(&bytes, name[0..length]) orelse "";
                const palette: data.Palette = .{ .red=0, .peach=1, .yellow=2, .green=3, .teal=4, .blue=5, .mauve=6 };
                const result: [6]u32 = .{tileHue(palette, name[0..length]), @intCast(letter.len), bytes[0], bytes[1], bytes[2], bytes[3]};
                try write(std.mem.asBytes(&result));
            },
            3 => {
                const total = try readUnsigned(u32);
                const active = try readUnsigned(u32);
                const capacity = try readUnsigned(u32);
                const window = WorkspaceWindow.centered(total, active, capacity);
                const result: [5]u32 = .{@intCast(window.first), @intCast(window.count), @intCast(window.total), @intCast(window.previous() orelse std.math.maxInt(u32)), @intCast(window.next() orelse std.math.maxInt(u32))};
                try write(std.mem.asBytes(&result));
            },
            4 => {
                var dimensions: [5]f32 = undefined;
                for (&dimensions) |*value| value.* = @bitCast(try readUnsigned(u32));
                var request: [4]u32 = undefined;
                for (&request) |*value| value.* = try readUnsigned(u32);
                const canvas: Canvas = .{.chrome=.{.ratio=dimensions[4], .body=@intCast(request[0]), .small=@intCast(request[1])}};
                const regions = try SidebarRegions.resolve(&canvas, .{.x=dimensions[0], .y=dimensions[1], .width=dimensions[2], .height=dimensions[3]}, request[2], request[3] != 0);
                const bounds: [5]Rect = .{regions.machines, regions.projects_header, regions.projects, regions.agents_header, regions.agents};
                var result: [20]f32 = undefined;
                for (bounds, 0..) |rect, index| {
                    result[index * 4 ..][0..4].* = .{rect.x, rect.y, rect.width, rect.height};
                }
                try write(std.mem.asBytes(&result));
            },
            5 => {
                var dimensions: [5]f32 = undefined;
                for (&dimensions) |*value| value.* = @bitCast(try readUnsigned(u32));
                const total = try readUnsigned(u32);
                const active = try readUnsigned(u32);
                const context: RailContext = .{.projection=.{.workspaces=.{.project_count=total}}, .active=if(total == 0) null else active};
                var sink: RailSink = .{};
                const rail: WorkspaceRail = .{.context=&context, .sink=&sink};
                var canvas: Canvas = .{.chrome=.{.ratio=dimensions[4], .body=13, .small=11}};
                try rail.capture(&canvas, .{.x=dimensions[0], .y=dimensions[1], .width=dimensions[2], .height=dimensions[3]});
                try write(std.mem.sliceAsBytes(sink.events[0..sink.count]));
            },
            6 => {
                const length = try readUnsigned(u32);
                if(length > 4096) return error.InvalidLength;
                var storage: [4096]u8 = undefined;
                for(storage[0..length]) |*byte| byte.* = try readUnsigned(u8);
                try write(pane_support.displayCwdName(storage[0..length]));
            },
            7 => {
                var lengths: [4]u32 = undefined;
                for(&lengths) |*length| { length.* = try readUnsigned(u32); if(length.* > 4096) return error.InvalidLength; }
                var fields: [4][4096]u8 = undefined;
                for(&fields, lengths) |*field, length| for(field[0..length]) |*byte| { byte.* = try readUnsigned(u8); };
                const model: ClientModel = .{
                    .tabs=.{.manual=fields[0][0..lengths[0]], .label_len=.{lengths[0]}, .application=fields[1][0..lengths[1]]},
                    .pane=.{.application=fields[1][0..lengths[1]], .path=fields[2][0..lengths[2]]},
                    .agent_snapshot=.{.entries=.{.{.title=fields[3][0..lengths[3]]}}},
                };
                var storage: [caption_bytes]u8 = undefined;
                try write(caption(&model, 0, &storage));
            },
            8 => {
                var identities: [3]u64 = undefined;
                for(&identities) |*identity| identity.* = try readUnsigned(u64);
                var lengths: [2]u32 = undefined;
                for(&lengths) |*length| { length.* = try readUnsigned(u32); if(length.* > 4096) return error.InvalidLength; }
                var names: [2][4096]u8 = undefined;
                for(&names, lengths) |*name, length| for(name[0..length]) |*byte| { byte.* = try readUnsigned(u8); };
                const model: ClientModel = .{
                    .tabs=.{.manual="", .label_len=.{0}, .application=names[0][0..lengths[0]], .foreground_pane=.{identities[1]}},
                    .pane=.{.id=identities[2], .application=names[1][0..lengths[1]], .path=""},
                    .pane_present=identities[0] != 0,
                    .agent_snapshot=.{.entries=.{.{.title=""}}},
                };
                try write(applicationName(&model, 0));
            },
            9 => {
                const room: f32 = @bitCast(try readUnsigned(u32));
                const ratio: f32 = @bitCast(try readUnsigned(u32));
                const count = try readUnsigned(u32);
                const focus = try readUnsigned(u32);
                if(count == 0 or count > 64 or focus >= count) return error.InvalidCount;
                var sizes: [64]OriginalStrip.Measure = undefined;
                for(sizes[0..count]) |*size| size.* = .{
                    .caption=@bitCast(try readUnsigned(u32)),
                    .chip=@bitCast(try readUnsigned(u32)),
                    .status=@bitCast(try readUnsigned(u32)),
                };
                const metrics = OriginalStrip.StripMetrics.of(.{.ratio=ratio, .body=13, .small=11});
                const layout = OriginalStrip.plan(sizes[0..count], focus, .{.room=room, .metrics=metrics});
                var result: [135]u32 = @splat(0);
                for(layout.widths, 0..) |width, index| result[index] = @bitCast(width);
                for(layout.fits, 0..) |fit, index| result[index + 64] = @intFromEnum(fit);
                result[128] = @intCast(layout.first);
                result[129] = @intCast(layout.end);
                result[130] = @intCast(layout.focus);
                result[131] = @intCast(layout.count);
                result[132] = @intCast(layout.hidden());
                result[133] = if(layout.hidden() == 0) std.math.maxInt(u32) else @intCast(OriginalStrip.nearestHidden(layout));
                result[134] = @bitCast(OriginalStrip.footprint(layout, metrics));
                try write(std.mem.asBytes(&result));
            },
            else => return error.InvalidKind,
        }
    }
}
'''


def sidebar_reference(root):
    source = (root / "src/model/layout/sidebar.zig").read_text()
    constants = [re.search(rf"pub const {name}: u16 = [0-9]+;", source).group(0)
                 for name in ("minimum_width", "minimum_workbench_width")]
    functions = []
    for marker in ("pub fn clampInteractive(", "fn maximumWidth("):
        start = source.index(marker)
        end = source.index("\n}", start) + len("\n}")
        functions.append(source[start:end])
    return "\n".join(constants + functions)


def source_function(source, marker):
    start = source.index(marker)
    end = source.index("\n}", start) + len("\n}")
    return source[start:end]


def tab_reference(root):
    source = (root / "src/model/workspace/tab_label.zig").read_text()
    limits = (root / "src/core/schema/types.zig").read_text()
    capacity = re.search(r"pub const max_tab_label_bytes = ([0-9]+);", limits).group(1)
    separator = re.search(r"const caption_separator = .*;", source).group(0)
    prefix = r'''
const pane_support = @import("pane_support");
const core = struct { const PaneId = u64; };
const caption_bytes = 128;
const caption_separator = " \u{00b7} ";
const CaptionPane = struct {
    id: u64 = 1,
    application: []const u8,
    path: []const u8,
    fn foregroundName(self: *const CaptionPane) []const u8 { return self.application; }
    fn cwdName(self: *const CaptionPane) []const u8 { return pane_support.displayCwdName(self.path); }
};
const CaptionTabs = struct {
    manual: []const u8,
    application: []const u8,
    label_len: [1]usize,
    foreground_pane: [1]u64 = .{1},
    location: [1]u64 = .{1},
    fn canonicalLabel(self: *const CaptionTabs, _: usize) []const u8 { return self.manual; }
    fn foregroundName(self: *const CaptionTabs, _: usize) []const u8 { return self.application; }
};
const CaptionAgent = struct {
    key: struct { pane_id: u64 = 1 } = .{},
    location: u64 = 1,
    title_state: enum { placeholder, ready } = .ready,
    title: []const u8,
    fn sessionTitle(self: *const CaptionAgent) []const u8 { return self.title; }
};
const CaptionAgents = struct {
    entries: [1]CaptionAgent,
    fn slice(self: *const CaptionAgents) []const CaptionAgent { return &self.entries; }
};
const ClientModel = struct { tabs: CaptionTabs, pane: CaptionPane, pane_present: bool = true, agent_snapshot: CaptionAgents };
const tab_layout = struct {
    fn focusedPaneConst(model: *const ClientModel, _: usize) ?*const CaptionPane { return if(model.pane_present) &model.pane else null; }
};
'''
    prefix = prefix.replace("const caption_bytes = 128;", f"const caption_bytes = {capacity};")
    prefix = re.sub(r"const caption_separator = .*;", lambda _: separator, prefix)
    return prefix + "\n".join(source_function(source, marker) for marker in ("pub fn caption(", "pub fn automatic(", "fn sessionTitle(", "fn applicationName("))


def strip_reference(root):
    source = (root / "src/gui/widgets/TabStrip.zig").read_text()
    limits = (root / "src/core/schema/types.zig").read_text()
    maximum = re.search(r"pub const max_tabs_per_workspace = ([0-9]+);", limits).group(1)
    constants = "\n".join(re.search(rf"const {name}(?:: f32)? = [0-9.]+;", source).group(0) for name in ("lead", "trail", "spacing", "strip_gap", "inactive_max", "selected_max", "selected_share", "caption_min", "counter_width", "cap_steps"))
    declarations = ["const Fit = enum { full, truncated, compact };"]
    for name in ("Metrics", "Measure", "Share", "Room", "Plan"):
        start = source.index(f"const {name} = struct")
        end = source.index("\n};", start) + len("\n};")
        declarations.append(source[start:end])
    functions = "\n".join(source_function(source, marker) for marker in ("fn plan(", "fn largestCap(", "fn footprint("))
    start = source.index("    const left_distance = ", source.index("fn drawCounter("))
    end = source.index("\n    var storage:", start)
    nearest = "fn nearestHidden(layout: Plan) usize { const model = .{.tabs=.{.count=layout.count}};\n" + source[start:end] + "\nreturn nearest;\n}"
    body = constants + "\n" + "\n".join(declarations) + "\n" + functions + "\n" + nearest
    body = re.sub(r"\bMetrics\b", "StripMetrics", body)
    return f"const OriginalStrip = struct {{\nconst ChromeMetrics = Metrics;\nconst max_tabs = {maximum};\n" + body + "\n};\n"


def chrome_reference(root):
    widgets = root / "src/gui/widgets"
    mark = (widgets / "WorkspaceMark.zig").read_text()
    chrome = (widgets / "ChromeMetrics.zig").read_text()
    regions = (widgets / "SidebarRegions.zig").read_text()
    row = (widgets / "WorkspaceRow.zig").read_text()
    rail = (widgets / "WorkspaceRail.zig").read_text()
    prefix = '''
const cellgrid = struct { pub const Color = u32; };
const data = struct { pub const Palette = struct { red: u32, peach: u32, yellow: u32, green: u32, teal: u32, blue: u32, mauve: u32 }; };
const label_size = struct { pub const Size = enum { terminal, title, body, small }; };
const Canvas = struct { chrome: Metrics };
'''
    metrics = "const Metrics = struct { ratio: f32, body: u16, small: u16, title: u16 = 0,\n"
    metrics += re.search(r"pub const sans_line_ratio: f32 = [0-9.]+;", chrome).group(0) + "\n"
    metrics += "\n".join(source_function(chrome, marker) for marker in ("pub fn px(", "pub fn text(", "pub fn rowHeight(")) + "\n};\n"
    workspace_row = "const WorkspaceRow = struct {\n" + source_function(row, "pub fn height(") + "\n};\n"
    sidebar = "const SidebarRegions = struct {\n"
    sidebar += "\n".join(re.search(rf"pub const {name}: f32 = [0-9.]+;", regions).group(0) for name in ("margin", "header_gap")) + "\n"
    sidebar += "\n".join(re.findall(r"^[a-z_]+: Rect = .*,$", regions, re.MULTILINE)) + "\n"
    sidebar += source_function(regions, "pub fn resolve(") + "\n};\n"
    rail_types = '''
const RailEvent = extern struct { kind: u32, first: u32, end: u32, x: f32, y: f32, width: f32, height: f32 };
const RailSink = struct {
    events: [130]RailEvent = undefined,
    count: usize = 0,
    fn append(self: *RailSink, kind: u32, range: [2]usize, bounds: Rect) void {
        self.events[self.count] = .{.kind=kind, .first=@intCast(range[0]), .end=@intCast(range[1]), .x=bounds.x, .y=bounds.y, .width=bounds.width, .height=bounds.height};
        self.count += 1;
    }
};
const RailSnapshot = struct {
    project_count: usize,
    fn projectOf(_: RailSnapshot, index: usize) usize { return index; }
    fn indexOf(self: RailSnapshot, index: usize) ?usize { return if(index < self.project_count) index else null; }
};
const RailContext = struct {
    projection: struct { workspaces: RailSnapshot },
    active: ?usize,
    fn workspaceId(self: *const RailContext) ?usize { return self.active; }
};
const WorkspaceRail = struct {
    context: *const RailContext,
    sink: *RailSink,
    fn drawMark(self: WorkspaceRail, _: *Canvas, bounds: Rect, index: usize) !void { self.sink.append(0, .{index, index+1}, bounds); }
    fn drawCounter(self: WorkspaceRail, _: *Canvas, bounds: Rect, range: [2]usize) !void { self.sink.append(if(range[0] == 0) 1 else 2, range, bounds); }
'''
    rail_types += "\n".join(re.search(rf"(?:pub )?const {name}: f32 = [0-9.]+;", rail).group(0) for name in ("button", "button_gap", "inset", "counter_height")) + "\n"
    rail_types += source_function(rail, "fn drawList(") + "\n"
    start = rail.index("    const side = @min(chrome.px(button), area.width - 1);")
    end = rail.index("\n}", start)
    rail_types += "fn capture(self: WorkspaceRail, canvas: *Canvas, area: Rect) !void { if(area.width <= 1 or area.height <= 0) return; const chrome = canvas.chrome;\n" + rail[start:end] + "\n}\n};\n"
    return prefix + metrics + workspace_row + sidebar + rail_types + source_function(mark, "fn tileHue(") + "\n" + source_function(mark, "fn initial(")


def title_record(pattern, workspace=b"", tab=b"", pane=b"", hostname=b"", suffix=b""):
    fields = (pattern, workspace, tab, pane, hostname, suffix)
    return b"\0" + struct.pack("<6I", *(len(value) for value in fields)) + b"".join(fields)


def records():
    patterns = (b"", b"{pane_title}", b"{tab}/{workspace}@{hostname}: {pane_title}",
                b"{unknown} {{tab}} {unfinished", b"{pane_title}{tab}", b"literal")
    for first in range(256):
        for second in range(256):
            yield title_record(b"a{pane_title}z", pane=bytes((first, second)))
    for length in range(270):
        for ending in (b"a", "中".encode(), "é".encode(), "🙂".encode()):
            for suffix in (b"", b"!", " — limit reached: x".encode(), b"s" * 257):
                yield title_record(b"{pane_title}", pane=b"a" * length + ending, suffix=suffix)
    randomizer = random.Random(0x7171E)
    for _ in range(20_000):
        values = [randomizer.randbytes(randomizer.randrange(300)) for _ in range(4)]
        suffix = randomizer.choice((b"", b"!", b"s" * randomizer.randrange(300)))
        yield title_record(randomizer.choice(patterns), *values, suffix=suffix)
    for host in range(256):
        for requested in range(256):
            yield b"\1" + struct.pack("<Iq", host, requested)
    for host in (0, 1, 41, 42, 61, 62, 80, 120, 65535):
        for requested in (-2**63, -1, 0, 1, 42, 65535, 65536, 2**63 - 1):
            yield b"\1" + struct.pack("<Iq", host, requested)


def chrome_records():
    for first in range(256):
        for second in range(256):
            name = bytes((first, second))
            yield b"\2" + struct.pack("<I", len(name)) + name
    for name in (b"", b"telar", b"Telar", "ñandú".encode(), "🧶 project".encode(), "中".encode()):
        yield b"\2" + struct.pack("<I", len(name)) + name
    for total, active, capacity in itertools.product(range(129), (0, 1, 7, 63, 127, 128, 200), (0, 1, 2, 3, 8, 16, 64, 128)):
        yield b"\3" + struct.pack("<3I", total, active, capacity)
    for width, height, ratio, count, machines in itertools.product((0, 1, 16, 52, 120, 280, 640), (0, 1, 16, 60, 100, 200, 932), (.5, .625, 1, 1.25, 2), (0, 1, 8, 128), (0, 1)):
        yield b"\4" + struct.pack("<5f4I", 0, 0, width, height, ratio, 13, 11, count, machines)
    randomizer = random.Random(0x51DEBA2)
    for _ in range(10_000):
        yield b"\4" + struct.pack("<5f4I", randomizer.uniform(-100, 100), randomizer.uniform(-100, 100), randomizer.uniform(0, 2000), randomizer.uniform(0, 2000), randomizer.uniform(.1, 4), randomizer.randrange(6, 65), randomizer.randrange(6, 65), randomizer.randrange(129), randomizer.randrange(2))
    for width, height, ratio, total in itertools.product((0, 1, 16, 52, 120), (0, 1, 36, 60, 100, 200, 932), (.5, .625, 1, 1.25, 2), (0, 1, 8, 64, 128)):
        for active in (0, total // 2, max(0, total - 1)):
            yield b"\5" + struct.pack("<5f2I", 0, 0, width, height, ratio, total, active)
    for _ in range(5_000):
        total = randomizer.randrange(129)
        active = randomizer.randrange(max(1, total))
        yield b"\5" + struct.pack("<5f2I", randomizer.uniform(-100, 100), randomizer.uniform(-100, 100), randomizer.uniform(0, 200), randomizer.uniform(0, 2000), randomizer.uniform(.1, 4), total, active)


def tab_records():
    paths = [b"", b"/", b"\\", b"///", b"/work/telar/", b"C:\\work\\telar\\", b"relative", b"/bad\xff/valid", b"/work/bad\nname", b"/work/\xff", "~/🧶 telar".encode()]
    for first in range(256):
        for second in range(256):
            pathsuffix = bytes((first, second))
            yield b"\6" + struct.pack("<I", len(pathsuffix)) + pathsuffix
    for length, suffix in itertools.product(range(60), (b"a", "ñ".encode(), "中".encode(), "🧶".encode())):
        paths.append(b"/work/" + b"a" * length + suffix * 3)
    for path in paths:
        yield b"\6" + struct.pack("<I", len(path)) + path
    for fields in itertools.product((b"", b"Manual", b"m" * 128), (b"", b"sh", b"Python", b"a" * 48), paths, (b"", b"Agent session", "Sesión 🧶".encode())):
        yield b"\7" + struct.pack("<4I", *(len(field) for field in fields)) + b"".join(fields)
    for present, remembered, focused, cached, actual in itertools.product((0, 1), range(3), range(3), (b"", b"sh", b"nvim", b"a" * 48), (b"", b"Python", b"git", "ñ".encode())):
        yield b"\10" + struct.pack("<3Q2I", present, remembered, focused, len(cached), len(actual)) + cached + actual


def strip_records():
    for count, width, ratio, caption, status in itertools.product((1, 2, 3, 4, 8, 16, 32, 64), (0, 1, 29, 60, 100, 180, 300, 500, 900, 1600), (.5, .625, 1, 1.25, 2), (0, 13.25, 120, 500), (0, 6, 12, 24)):
        sizes = b"".join(struct.pack("<3f", caption + index, 20 * ratio, status * ratio) for index in range(count))
        for focus in sorted({0, count // 2, count - 1}):
            yield b"\11" + struct.pack("<2f2I", width, ratio, count, focus) + sizes
    randomizer = random.Random(0x7AB57A1)
    for _ in range(10_000):
        count = randomizer.randrange(1, 65)
        ratio = randomizer.uniform(.1, 4)
        sizes = b"".join(struct.pack("<3f", randomizer.uniform(0, 800), 20 * ratio, randomizer.choice((0, 6, 12, 24)) * ratio) for _ in range(count))
        yield b"\11" + struct.pack("<2f2I", randomizer.uniform(0, 5000), ratio, count, randomizer.randrange(count)) + sizes


def main():
    parser = argparse.ArgumentParser(description="Compare presentation calculations with the original Zig client")
    parser.add_argument("--compiler", default="clang++")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--chrome-only", action="store_true")
    group.add_argument("--tabs-only", action="store_true")
    group.add_argument("--strip-only", action="store_true")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    cases = list(strip_records() if options.strip_only else tab_records() if options.tabs_only else chrome_records() if options.chrome_only else itertools.chain(records(), chrome_records(), tab_records(), strip_records()))
    payload = b"".join(cases)
    with tempfile.TemporaryDirectory(prefix="telar-presentation-") as directory:
        work = Path(directory)
        (work / "probe.cpp").write_text(cpp_probe)
        (work / "probe.zig").write_text(zig_probe.replace("__SIDEBAR__", sidebar_reference(root)).replace("__CHROME_REFERENCE__", chrome_reference(root)).replace("__TAB_REFERENCE__", tab_reference(root)).replace("__STRIP_REFERENCE__", strip_reference(root)))
        includes = ["-I" + str(root / "services" / name) for name in ("gui-cpp", "runtime-cpp")] + ["-I" + str(root / "dlls/telar-client/include")]
        subprocess.run([options.compiler, "-std=c++23", "-O2", *includes, str(work / "probe.cpp"), "-o", str(work / "cpp")], check=True)
        subprocess.run(["zig", "build-exe", "-O", "ReleaseSafe", "-lc", "--dep", "original", "--dep", "workspace_window", "--dep", "gfx", "--dep", "pane_support", f"-Mroot={work / 'probe.zig'}", f"-Moriginal={root / 'src/client/presentation/window_title.zig'}", f"-Mworkspace_window={root / 'src/gui/widgets/WorkspaceWindow.zig'}", f"-Mgfx={root / 'lib/gfx/root.zig'}", f"-Mpane_support={root / 'src/model/panes/pane_support.zig'}", f"-femit-bin={work / 'zig'}"], check=True)
        expected = subprocess.run([str(work / "zig")], input=payload, capture_output=True, check=True).stdout
        actual = subprocess.run([str(work / "cpp")], input=payload, capture_output=True, check=True).stdout
        if actual != expected:
            offset = 0
            for index, case in enumerate(cases):
                actual_length = struct.unpack_from("<I", actual, offset)[0]
                expected_length = struct.unpack_from("<I", expected, offset)[0]
                end = offset + 4 + expected_length
                if actual_length != expected_length or actual[offset:end] != expected[offset:end]:
                    if case[0] == 9 and actual_length == expected_length == 540:
                        actual_words = struct.unpack_from("<135I", actual, offset + 4)
                        expected_words = struct.unpack_from("<135I", expected, offset + 4)
                        differences = []
                        for word, (left, right) in enumerate(zip(actual_words, expected_words)):
                            if left != right:
                                field = f"width[{word}]" if word < 64 else f"fit[{word - 64}]" if word < 128 else ("first", "end", "focus", "count", "hidden", "nearest", "footprint")[word - 128]
                                if word < 64 or word == 134:
                                    left, right = (struct.unpack("<f", struct.pack("<I", value))[0] for value in (left, right))
                                differences.append((field, left, right))
                        raise RuntimeError(f"Tab strip mismatch at record {index}, area/count/focus={struct.unpack_from('<2f2I', case, 1)}, differences={differences}")
                    raise RuntimeError(f"Presentation mismatch at record {index}, input={case!r}, C++={actual[offset:offset + 4 + actual_length]!r}, Zig={expected[offset:end]!r}")
                offset = end
            raise RuntimeError("Probe output lengths differ")
    print(f"Matched {len(cases):,} presentation records byte-for-byte against the original Zig client")


if __name__ == "__main__":
    main()
