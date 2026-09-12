# Native macOS rendering with Metal 4

The GUI requires macOS 26 and a GPU reporting `MTLGPUFamilyMetal4` support.
The application bundle declares the OS minimum; the CLI GUI entrypoint checks
it before creating the view. Unsupported systems fail explicitly. The TUI and
runtime do not use this rendering API.

`src/gui/macos/window.m` owns the display link and one reusable GPU submission
slot. Shared client behavior, terminal geometry and shaping remain in their
existing packages. The temporary socket driver is independent of this slot;
the step 9 inbox/outbox migration can replace it without replacing GPU resources.

## From changes to delivery

1. `requestDraw` marks `dirty` and unpauses a view-bound `CADisplayLink` when
   no frame is in flight. It also attempts to draw immediately when the frame
   budget allows it. Input does not have to wait for a display callback after
   an idle interval.
2. `drawIfReady` checks visibility and the next eligible drawing time. If work
   must wait, `displayDidRefresh:` retries on the display clock. Once ready,
   the view obtains a drawable from `CAMetalLayer`, pauses notifications and
   submits the scene. There is no separate dispatch timer.
3. `drawWithDrawable:` uses the actual drawable texture dimensions, prepares
   the scene, uploads changed atlas pixels and updates the vertex data.
4. The allocator resets only after the previous GPU submission has completed.
   The command buffer begins encoding, the render encoder binds the pipeline
   and argument table, and one instanced draw paints the scene.
5. The queue waits for the drawable, commits the command buffer, signals the
   drawable and requests presentation. Queue waits are GPU-side operations;
   they do not block keyboard processing on the CPU.
6. Commit feedback reports success or failure. It releases the shutdown wait
   group on Metal's feedback queue, then dispatches delivery to the main queue.
   Only successful delivery can retire client damage and generate an ACK.
   An unrecoverable GPU failure closes this client.
7. Delivery unsets `in_flight` and schedules another update only if work remains.
   Changes arriving during GPU work coalesce into `dirty`; no frame replay is
   queued. A quiet view keeps its display link paused.

The link requests 60 Hz. A frame budget carries the cadence forward across
callback jitter and resets after idle; it never queues missed frames. The system
chooses actual callback timing. `displaySyncEnabled` remains enabled.
This controls scheduling and presentation, not a promise of lower input latency.

A measured `CAMetalDisplayLink` implementation required input-driven frames to
wait for its supplied drawable and regressed the GPU-completion endpoint. The
final implementation uses `CADisplayLink` for pacing and leaves presentation
synchronized by `CAMetalLayer`. This permits immediate work after idle while
still pacing continuous output against the view's display. See
[NSView display links](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)).

## Resource lifetime

| Resource | Purpose | Reuse boundary |
| --- | --- | --- |
| `MTL4CommandQueue` | Submit work and synchronize drawable ownership | View lifetime |
| `MTL4CommandBuffer` | Encode the current frame | Previous GPU completion |
| `MTL4CommandAllocator` | Back encoded commands with reusable memory | Reset after GPU completion |
| `MTL4ArgumentTable` | Bind two buffer addresses and one texture ID | Updated before encoding draw |
| `MTLResidencySet` | Make viewport, quad, atlas and drawable allocations accessible | Changed after previous completion; at most four allocations |
| Viewport buffer | Two floating-point dimensions read by the vertex shader | Written after previous completion |
| Quad buffer and atlas | Scene instances and glyph coverage | Retained; replaced only when required capacity changes |
| Active drawable | Keep the render destination alive through GPU work | Released on delivery |

Metal 4 command buffers do not retain the resources they reference. Strong
view ivars own those resources; residency declares GPU accessibility and is
not a substitute for lifetime ownership. One frame in flight prevents CPU writes
from racing with GPU reads. There is one render pass and no GPU-produced input
for a later pass, so the production renderer needs no inter-pass barrier.
The pixel benchmark adds a render-to-copy barrier for its diagnostic readback.

Commit options are reused, but their feedback handler is registered for each
submission: the installed implementation consumes the registration on commit.
Registering it only at initialization delivers the first frame and stalls the
second. The multi-frame native test covers this behavior.

Closing invalidates the display link and cancels the socket wake source. It
waits for submitted GPU work before releasing resources. The feedback queue
releases this wait without requiring the main queue to run. A queued delivery
checks `closed` and cannot call a detached Zig context. The runtime owns the
shell and remains alive after this window closes.

## Objective-C reading notes

`id<MTL4CommandBuffer>` means an object implementing a protocol, rather than
an instance of a particular concrete class. `[queue commit:batch count:1
options:commit_options]` sends the `commit:count:options:` message with three
arguments. Property assignment such as `display_link.paused = YES` calls a
setter; it is not direct public-field access.

The build enables ARC. `CADisplayLink` retains its target; closing calls
`invalidate` to release that reference and remove it from the run loop. The
feedback block captures a weak view to avoid a
view/block ownership cycle, then resolves it to a strong local reference on
the main queue. `view->in_flight` accesses an ivar directly. The dispatch group
is captured strongly so completion can release a close wait independently of
the view's weak reference.

The MSL source lives in `src/gui/shaders/quad.metal`, next to the Vulkan
shaders. Objective-C embeds its bytes with C23 `#embed`; both the application
and native window test enable that language standard. The executable therefore
needs no shader file at runtime. `buildPipeline` compiles the embedded source during initialization using
`MTL4Compiler` and `MTL4LibraryDescriptor`, explicitly selecting MSL 4.0.

Pipeline construction uses the Metal 4 compiler API throughout:

1. `MTLDevice.newCompilerWithDescriptor:error:` creates an `MTL4Compiler`.
2. `MTL4LibraryDescriptor` supplies the source and MSL 4.0 compile options;
   `MTL4Compiler.newLibraryWithDescriptor:error:` creates the `MTLLibrary`.
3. Two `MTL4LibraryFunctionDescriptor` instances select `quad_vertex` and
   `quad_fragment` by name from that library.
4. `MTL4RenderPipelineDescriptor` selects those function descriptors and
   configures the BGRA target and alpha blending through
   `MTL4RenderPipelineColorAttachmentDescriptor`.
5. `MTL4Compiler.newRenderPipelineStateWithDescriptor:compilerTaskOptions:error:`
   creates the reusable `MTLRenderPipelineState`.

Compiler and descriptors are initialization locals, not per-frame objects.
`MTLDevice`, `MTLLibrary`, `MTLCompileOptions`, `MTLRenderPipelineState`, buffers,
textures and residency sets remain shared API types; they have no separate
Metal 4 replacements for these operations. No classic command submission or
classic pipeline/library creation path remains in the native renderer. See
Apple's [Metal 4 core API guide](https://developer.apple.com/documentation/metal/understanding-the-metal-4-core-api).

## Verification

```sh
MTL_DEBUG_LAYER=1 zig build test-gui-window
zig build test-gui
python3 tools/gui_lifecycle.py /absolute/path/to/telar /tmp/telar-lifecycle-run
```

The native test checks successful ordered delivery, non-square viewport
geometry, native text/control input, resize, idle stability, coalesced requests
and closing immediately after GPU submission. The final frame deliberately has
no client delivery after close. The lifecycle tool exercises a real shell,
checks `stty size` before and after resizing the content view, and checks that
the shell PID survives detach before stopping its isolated runtime. Resizing
the view directly prevents a tiling window manager from undoing the test.

Performance samples and limitations are recorded in
[the Metal 4 measurement](../performance/native-terminal/metal4.md).
