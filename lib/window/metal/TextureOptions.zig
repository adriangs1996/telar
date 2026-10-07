const Size = @import("Size.zig").Size;
const PixelFormat = @import("PixelFormat.zig").PixelFormat;
const StorageMode = @import("StorageMode.zig").StorageMode;
const TextureUsage = @import("TextureUsage.zig").TextureUsage;

size: Size,
format: PixelFormat,
storage: StorageMode,
usage: TextureUsage,
