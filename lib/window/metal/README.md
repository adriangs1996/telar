# Metal 4 bindings

These are internal bindings used by `MacosSurface`. They contain no frame scheduler, image quotas or application
state.

The build supplies `@import("metal")` only to the macOS window implementation
and native tests. The common renderer uses canvas operations without importing
GPU bindings. Application packages receive `telar-window`; the common renderer lives in
`src/gui/render`. There is no standalone `telar-metal` library contract.
The existing bindings and their GPU/ABI tests are preserved for incremental use.

`Object` is zig-objc's object handle, not a distinct type per Metal protocol:
callers must pass an object implementing the requested operation. Native handles
and feedback lifetime tools remain internal to the surface implementation.

The build creates this internal module only for macOS.
`createDevice` requires Metal 4 support. Metal 4 operations require macOS 26;
missing classes and failed native creation are errors. The GPU tests require
supported hardware and fail rather than silently skip.

## Binding operations

| Capability | Operations |
| --- | --- |
| Device and shaders | `createDevice`, `createCompiler`, `compileLibrary`, `createRenderPipeline` with named entry points and blend options |
| Resource access | `createTexture`, `createBuffer`, `bufferBytes`, `textureSize`, `uploadTexture`, `readTexture` |
| GPU bindings and residency | Create an argument table, bind buffers/textures, stage and commit residency, attach sets to a queue |
| Submission and feedback | Create queue/command memory, begin/end encoding, select pipeline/arguments, draw, submit and receive feedback |
| Drawables | `createLayer`, `resizeLayer`, `nextDrawable`, `drawableTexture`, queue wait/signal and `present` |

Types describe these operations and their lifetimes within the backend.
Texture/pipeline/layer options contain caller choices; implementation
objects such as NSStrings and native descriptors are created and released
inside the library. `createClearPass` explicitly selects clear/store actions;
other pass modes are added only when a consumer needs them. `submit` sends one
command buffer. No batching or scheduling policy is introduced.

```zig
const metal = @import("metal");

fn createTarget(gpu: metal.Object) !metal.Object {
    return metal.createTexture(gpu, .{
        .size = .{ .width = 640, .height = 480 },
        .format = .bgra8_unorm,
        .storage = .shared,
        .usage = .{ .render_target = true },
    });
}
```

## Ownership and execution

- `create*` operations and `compileLibrary` return owned objects. Release each successful result exactly once.
  Copying a Zig handle does not retain the object. Use `retain` explicitly when
  extending a borrowed lifetime. An autorelease pool is still required around
  work that creates autoreleased native objects.
- Encoders, drawable textures and `nextDrawable` return
  borrowed objects. Retain a drawable through GPU consumption. Metal 4 command
  buffers do not retain all resources they reference. Keep resources and command
  memory alive; reset or overwrite them only after consumption ends.
- `NSError` outputs use `*Id`, where `Id` is an already-nullable C pointer. Public
  operations clear the output before a call and return Zig errors for failed
  creation/compilation. Native errors are borrowed; inspect or retain them
  before draining the surrounding pool. A nullable returned object becomes
  `?Object` only after crossing the native ABI.
- Feedback may arrive on Metal's queue. Capture results there and return them
  to the owner before touching application state. Raw Zig pointers captured in
  blocks are not retained; their targets must survive the callback. The native
  API copies the block. Re-register the handler before every commit. Explicit
  block copies need matching releases.
- Upload/readback calls expose pointers and native row strides. The caller
  validates dimensions, byte extents and synchronization. Bindings do not add
  bounds checks, queues, locks or a shutdown policy. `nextDrawable` can block or
  return null. The renderer will own those policies in a later slice.

## Binding sources

The dependency is pinned to
[zig-objc c8de82ff](https://github.com/mitchellh/zig-objc/tree/c8de82ff80281215ad92900866dab7103a8efa8b),
also used by the Ghostty revision reviewed for this migration. Native signatures
and constants follow the installed Apple SDK's Metal and QuartzCore headers;
the ABI probe independently compiles those headers.

The pinned bridge does not convert nullable Object structs at the C boundary.
These bindings exchange raw ids there. It also chooses `objc_msgSend_fpret` for
`f64` on x86_64. `objects.double` uses ordinary `objc_msgSend`, as specified for
double on both supported 64-bit ABIs in `objc/message.h`; x86_64 fpret is for
long double. GPU execution is validated on the test machine, not inferred for
every architecture from compilation.
