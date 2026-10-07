const builtin = @import("builtin");

pub const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("telar_gui.h");
    @cInclude("time.h");
    if (builtin.os.tag == .linux) {
        @cInclude("wayland-client.h");
        @cInclude("xdg-shell-client-protocol.h");
        @cInclude("vulkan_swapchain.h");
        @cInclude("vulkan_pipeline.h");
        @cInclude("vulkan_resources.h");
        @cInclude("vulkan_images.h");
        @cInclude("outputs.h");
        @cInclude("registry.h");
        @cInclude("cursor.h");
        @cInclude("clipboard.h");
        @cInclude("decoration.h");
        @cInclude("background_effect.h");
        @cInclude("text-input-unstable-v3-client-protocol.h");
        @cInclude("xkbcommon/xkbcommon.h");
        @cInclude("xkbcommon/xkbcommon-compose.h");
        @cInclude("linux/input-event-codes.h");
        @cInclude("sys/mman.h");
        @cInclude("sys/stat.h");
        @cInclude("fcntl.h");
        @cInclude("stdlib.h");
        @cInclude("string.h");
        @cInclude("accessibility_bridge.h");
        @cInclude("pthread.h");
        @cInclude("display_rate.h");
        @cInclude("semaphore.h");
        @cInclude("sys/eventfd.h");
        @cInclude("unistd.h");
        @cInclude("errno.h");
        @cInclude("poll.h");
    }
});
