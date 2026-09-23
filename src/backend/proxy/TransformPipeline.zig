const middleware = @import("middleware.zig");
const Transformer = @import("Transformer.zig");
const HeaderView = @import("HeaderView.zig");
const EffectBatch = @import("EffectBatch.zig");
const Headers = @import("Headers.zig");
/// Immutable after listener startup. A callback failure returns `preserve`, so
/// one extension cannot partially apply a batch or corrupt later middleware.
const TransformPipeline = @This();

transformers: [middleware.max_transformers]Transformer = undefined,
len: u8 = 0,

pub fn add(self: *TransformPipeline, transformer: Transformer) !void {
    if (self.len == self.transformers.len) {
        return error.TooManyProxyTransformers;
    }
    self.transformers[self.len] = transformer;
    self.len += 1;
}

pub const Request = @import("Request.zig");

/// Applies every configured transformer atomically to one header block.
///
/// ```zig
/// const changed = pipeline.apply(.{ .io = io, .context = context, .headers = &headers });
/// ```
pub fn apply(self: *const TransformPipeline, request: Request) bool {
    const headers = request.headers;

    var changed = false;
    for (self.transformers[0..self.len]) |transformer| {
        var view_storage: [middleware.max_header_fields]HeaderView = undefined;
        var effects: EffectBatch = .{};
        const status = transformer.transform(
            transformer.context,
            .{
                .io = request.io,
                .snapshot = .{ .context = request.context, .fields = headers.views(&view_storage) },
                .effects = &effects,
            },
        );
        if (status == .preserve or effects.len == 0) {
            continue;
        }
        var candidate: Headers = undefined;
        candidate.copyFrom(headers);
        candidate.apply(effects.effects[0..effects.len]) catch continue;
        headers.copyFrom(&candidate);
        changed = true;
    }
    return changed;
}
