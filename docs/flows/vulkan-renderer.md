# Native Linux rendering with Vulkan

The Linux GUI uses Wayland and Vulkan 1.3 with `dynamicRendering`,
`synchronization2`, and `VK_EXT_swapchain_maintenance1`. The instance also
requires `VK_KHR_get_surface_capabilities2` and `VK_EXT_surface_maintenance1`.
Device selection checks the API version and features and requires one queue
that supports both graphics and presentation. Unsupported systems fail during
initialization. These requirements apply to the GUI, not the TUI or runtime.

## Ownership

All paths below are relative to `src/gui/linux/`.

| File | Owns |
| --- | --- |
| [window.c](../../src/gui/linux/window.c) | Wayland toplevel, geometry, dirty state, Zig callbacks and teardown ordering |
| [input.c](../../src/gui/linux/input.c) | Keyboard translation, repeat and nonblocking clipboard reads |
| [frame_clock.c](../../src/gui/linux/frame_clock.c) | One pending Wayland frame callback and the 60 Hz submission budget |
| [frame_worker.c](../../src/gui/linux/frame_worker.c) | One borrowed sealed scene, worker thread and completion wakeup |
| [renderer.c](../../src/gui/linux/renderer.c) | Assembly, reusable command buffer, render fence and submission flow |
| [vulkan_device.c](../../src/gui/linux/vulkan_device.c) | Instance, surface, device, queue and memory capabilities |
| [vulkan_swapchain.c](../../src/gui/linux/vulkan_swapchain.c) | Swapchain images, views, presentation semaphores and fences |
| [vulkan_pipeline.c](../../src/gui/linux/vulkan_pipeline.c) | Shader modules, pipeline, descriptor layout/set and sampler |
| [vulkan_resources.c](../../src/gui/linux/vulkan_resources.c) | Persistently mapped quad/staging buffers, glyph atlas and upload barriers |
| [shaders.c](../../src/gui/linux/shaders.c) | Embedded SPIR-V and compile-time checks of the shared quad layout |

The window sees only the renderer and worker contracts. Vulkan components do
not call Zig or inspect input state. After initialization, the worker owns GPU
operations until it is joined. The window alone processes Wayland callbacks,
mutates scheduling state and delivers presentation tokens to Zig.

The existing retained geometry, damage tracking and shaping cache in the Zig
GUI adapter are shared with Metal. This change does not duplicate them in
Vulkan. Changed atlas versions trigger uploads; unchanged atlas pixels stay on
the GPU. Quad data is copied into a reusable mapped buffer for each submitted
scene, and the GPU draws the whole scene. This is not partial GPU rendering.

## Shader compilation and pipeline

`build/linux_gui.zig` runs `glslc --target-env=vulkan1.3 -O -mfmt=c` on
`src/gui/shaders/quad.vert` and `quad.frag`. Their generated initializers are
build dependencies and are included by `shaders.c`. Editing GLSL automatically
invalidates shader compilation. There are no checked-in `.spv` copies to
regenerate and no shader files to locate at runtime. Both the application and
the native integration test use this build helper.

At initialization, `vulkan_pipeline.c` creates `VkShaderModule` objects from
the embedded words, supplies vertex and fragment `main` entrypoints to
`vkCreateGraphicsPipelines`, and destroys the temporary modules afterwards.
`VkPipelineRenderingCreateInfo` specifies the selected swapchain format.
Dynamic rendering uses `vkCmdBeginRendering` with the acquired image view;
there are no `VkRenderPass` or `VkFramebuffer` objects. See the Khronos
[dynamic rendering example](https://docs.vulkan.org/samples/latest/samples/extensions/dynamic_rendering/README.html).

Binding 0 is a storage buffer containing 48-byte quads. Binding 1 is the glyph
atlas and sampler. An eight-byte vertex push constant holds drawable width and
height. The shaders use instancing, six vertices per quad, and the same alpha
blending factors as Metal. Surface selection uses the core sRGB nonlinear
color space, preferring BGRA8 UNORM.

## From damage to delivery

1. A socket wake or configure event marks the window dirty. Requests coalesce
   while a frame is in flight or a compositor callback is pending.
2. When ready, the window requests `wl_surface.frame`, prepares one sealed
   scene through the Zig callback, and lends it to the worker. The frame
   callback is registered before Vulkan presents and commits the surface.
3. The worker recreates stale or resized swapchains and acquires an image.
   Acquisition has a 100 ms timeout so an unavailable image does not impose
   an unbounded acquisition wait on window close. A transient failure returns
   `RETRY`; it does not retire damage.
4. The renderer resets its completed command buffer, updates mapped buffers,
   uploads changed atlas pixels, and records dynamic rendering. Explicit
   `vkCmdPipelineBarrier2` transitions protect atlas transfers/sampling and
   swapchain color attachment/presentation use.
5. `vkQueueSubmit2` waits for image acquisition at color attachment output and
   signals the acquired image's presentation semaphore after command execution.
   The worker queues FIFO presentation and waits for the render fence.
6. Completion wakes the window. Only `DELIVERED` calls the Zig completion with
   success and retires captured damage. `OUT_OF_DATE` requests recreation and
   retries without retiring damage. Cell ACKs already followed shared model
   application and do not release GPU storage. Fatal errors close this client.
7. The Wayland frame callback releases the pacing gate. It does not generate
   an ACK. Further rendering requires both dirty state and an available worker.
   A quiet window requests no further callbacks or draw-deadline wakeups.

Wayland supplies the compositor's pacing hints and FIFO synchronizes
presentation. A monotonic deadline also caps submission at 60 Hz, matching
Metal's budget on faster displays. The existing native poll loop uses the
remaining deadline only when a dirty window has no callback or GPU work
outstanding. There is no periodic timer. Cadence carries forward across small
wake jitter and resets after idle; a dirty window can then submit immediately.
Neither callback
arrival nor render-fence completion proves physical scanout. See the
[Wayland surface protocol](https://wayland.freedesktop.org/docs/html/apa.html#protocol-spec-wl_surface).

## Lifetimes, bounds and shutdown

The worker rejects a second submission until completion is taken. The sealed
scene's pointers remain borrowed until `take` or `destroy` returns. Normal
completion occurs after the GPU fence. Closing first disconnects frame
callbacks, then stops and joins the worker before destroying GPU resources or
the Zig owner. No completion is delivered to a detached context. The temporary
worker is independent of resource reuse and can be replaced by the step 9
inbox/outbox driver without redesigning the renderer.

There is one command buffer, one render fence and one acquire semaphore.
Swapchains are bounded to eight images. Each image has its own presentation
semaphore and a maintenance1 presentation fence. A render fence alone does not
prove that presentation has released its semaphore. Reuse follows image
acquisition; resize and shutdown wait for pending presentation fences before
destroying their resources. See Khronos's
[semaphore reuse guide](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html).

Mapped host-coherent buffers grow geometrically and remain mapped between
frames. Memory types and hardware limits are cached at device selection.
Scene dimensions and storage-buffer sizes are checked against device limits;
shared GUI preparation already bounds the source scene. Resources and
bindings change only after prior GPU consumption. A swapchain format change
rebuilds the pipeline and its bound resources together. Partially initialized
components are safe to destroy.

## Verification

On a Linux Wayland desktop with the build dependencies and validation layer:

```sh
VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation VK_LAYER_VALIDATE_SYNC=1 \
  zig build test-gui-window
zig build test-gui-worker test-gui codestyle
```

The native test paints changing atlas pixels across multiple frames, checks
ordered completion, coalescing and idle stability. Test-only Vulkan
interposition forces `OUT_OF_DATE` on acquisition and presentation and checks
two unsuccessful deliveries before recovery. A second run rejects an invalid
scene after image acquisition and verifies cleanup without successful delivery.
The worker test rejects an
overlapping submission, consumes a completion once, and closes while a
consumer is still borrowing its frame.

From the host, `python3 tools/vm/gui-terminal-test.py /tmp/telar-vulkan-check`
builds and runs a real shell in the existing Fedora VM. It checks input, UTF-8
paste, PTY resize, close and reattachment to the same shell PID. It captures
screenshots and fails on Vulkan validation errors.

Validation on 2026-09-12 used Fedora aarch64 and Mesa llvmpipe 25.3.6,
reporting Vulkan 1.4.328. The real-shell test changed `stty size` from `37 70`
to `30 100` and reattached to the same PID with no validation errors. This is
software-renderer functional validation, not a hardware latency measurement.
