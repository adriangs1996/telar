# Surface events

Every Lua UI uses the same event dispatcher. Register element handlers with
`ui.on(node, name, callback)` and surface handlers with
`ui.on(ui.surface, name, callback)`. Each subscription returns an idempotent
unsubscribe function. Multiple handlers run in registration order.

Callbacks run on the GUI thread. An exception is logged with its Lua stack
trace; it does not escape into Qt or suppress other subscriptions. A failed
callback contributes no acceptance, capture or focus request.

## Event delivery

Element events target the frontmost participating element under the pointer,
then propagate through its visual parents. Hit testing respects stacking,
transforms, visibility, enabled state, clipping and filled Shape geometry.
Decorative elements without subscriptions do not block interactive siblings.
Surface events, hover transitions and lifecycle events do not propagate.

Every event contains `type`, `target`, `current_target`, `timestamp_ms` and
`accepted`. Targets are UI object handles and support equality comparisons.
The timestamp uses a monotonic clock in milliseconds. Pointer events also
contain `position`, `x`, `y` and `surface_position`. Positions use logical
units, with an origin at the top left. `position` is relative to the current
handler's element; `surface_position` is relative to the surface.

| Method | Effect |
| --- | --- |
| `event:accept()` | Consume the event so Qt does not also process it. Later Lua handlers can see `accepted = true`. |
| `event:accept("copy")` | Accept a drag/drop operation. Other actions are `move` and `link`. |
| `event:stop_propagation()` | Stop delivery to visual parents after the current element's handlers. |
| `event:capture_pointer()` | Route the pointer's subsequent movement and release to this element. Valid during down or movement. Also accepts the event. |
| `event:release_pointer()` | Release this pointer's capture. |
| `event:focus()` | Request keyboard focus for the current element after its callback returns. |

Event tables are snapshots. Changing them after the callback returns has no
effect on native event processing. Returning a value has no effect; use the
methods above. Accepting an event and stopping propagation are independent.

```lua
local cancel = ui.on(panel, "pointer_down", function(event)
    if event.button == "left" then
        event:capture_pointer()
        event:focus()
    end
end)

ui.on(panel, "pointer_move", function(event)
    if #event.buttons > 0 then
        print(event.x, event.y)
    end
end)

-- Call cancel() when this subscription is no longer needed.
```

## Pointer and scroll

| Event | Additional fields |
| --- | --- |
| `hover` | `inside` reports entry or exit. |
| `pointer_down`, `pointer_move`, `pointer_up` | `pointer_id`, `device_id`, `device`, `button`, `buttons`, `modifiers`, `global_position`, `pressure`. |
| `pointer_cancel` | Pointer fields plus `reason`. |
| `click`, `double_click` | Pointer fields from the release. |
| `scroll` | `pixel_delta`, `angle_delta`, `phase`, `inverted`, `modifiers`. |

Devices are `mouse`, `touchpad`, `touch` or `pen`. `device_id` is a string,
preserving native integer identifiers without Lua number precision loss.
Pointer IDs distinguish concurrent points from the same device. Button names
include `left`, `right`, `middle`, `back`, `forward`, `extra_N` and `none`.
`buttons` is an array of the currently pressed buttons. Touch contacts use
the primary button convention.

`modifiers` has boolean `shift`, `control`, `alt`, `meta` and `keypad` fields.
A click requires a press and release within the pressed element without
movement exceeding the system drag threshold. A native double click also
produces click events; its second release produces `double_click`.

Capture ends on release, explicit release, cancellation or unmount.
Cancellation reasons include `capture_lost`, `focus_lost`, `surface_hidden`,
`target_unavailable`, `system_cancelled` and `unmount`.

Scroll phases are `none`, `begin`, `update`, `end` and `momentum`. Pixel
deltas are optional native scroll distances; angle deltas use eighths of a
degree. Preserve both representations for devices and platforms that do
not supply reliable pixel deltas. `inverted` describes natural scrolling.

## Focus, keyboard and text

| Event | Additional fields |
| --- | --- |
| `focus_in`, `focus_out` | `reason`. |
| `key_down`, `key_up` | `key`, `key_code`, `scan_code`, `modifiers`, `repeat`. |
| `text_input` | `text`, `replacement_start`, `replacement_length`. |
| `text_composition` | Pending `text` and an `attributes` array. Empty text clears composition. |

`key` is Qt's portable key name; `key_code` is its numeric Qt key and
`scan_code` is the platform's physical scan code. Keyboard and text events
propagate from the focused element, or from the root if no element has focus.
They are local to the surface and do not register global shortcuts.

Printable key presses produce `text_input` unless their `key_down` was
accepted. Input methods produce pending composition and committed text
separately. Attributes include format spans, cursor position, selection and
language. Committed text may replace surrounding text using the supplied
replacement offsets. Accept handled text events to prevent duplicate native
editing. Use a Qt text input or maintain your own text state and rendering.

For a custom input, call `ui.input_method(node, options)` whenever its text,
selection or caret changes. Options are `enabled`, `surrounding_text`,
`cursor_position`, `anchor_position` and `cursor_rect`.
The rectangle has `x`, `y`, `width` and `height` in element coordinates.
Positions and replacement lengths use UTF-16 code units, matching Qt and
native input methods; Lua strings remain UTF-8.

`ui.focus(node)` explicitly requests focus. Calls during initial script
construction are deferred until that candidate activates. On macOS a
nonactivating panel can receive keyboard focus without becoming the main
application window. Hover never requests focus.

## Drag and drop

`drag_enter`, `drag_move`, `drag_leave` and `drop` carry `formats`, `data`,
`urls`, and optional `text` and `html`. `data` maps MIME types to binary Lua
strings. Enter/move/drop also carry pointer coordinates, `modifiers`,
`possible_actions` and `proposed_action`. URLs retain their schemes; local
files use `file:` URLs and their contents are not read automatically.

Accept `drag_enter` and subsequent `drag_move` events for the target to
receive a drop. Accepting without an explicit action uses the native proposed
action. Unsupported actions are rejected. The total MIME payload is limited
to 16 MiB and cached during the drag. This receives native drag operations;
moving a UI element within Telar uses pointer capture.

## Gestures

`gesture` contains `kind`, `phase`, `value`, `delta`, `finger_count`, pointer
coordinates and modifiers. It forwards gestures recognized by the platform;
availability depends on the input device, OS and desktop configuration.

Kinds are `sequence`, `pinch`, `rotate`, `pan`, `swipe` and `smart_zoom`.
Phases are `begin`, `update`, `end` and `discrete`. Sequence begin/end bracket
continuous streams; pinch and rotation may interleave. Pinch values are
incremental scale deltas, rotation and swipe values are degrees, and pan
supplies displacement in `delta`. Two-finger scrolling uses `scroll`.

## Surface state

| Event | Additional fields |
| --- | --- |
| `resize` | `width`, `height`, `old_width`, `old_height`. |
| `screen_changed` | `value` and `previous` monitor descriptions. |
| `scale_changed` | `value` and `previous` scale factors. |
| `safe_area_changed` | `value` and `previous` safe-area descriptions. |
| `visibility_changed` | `value` and `previous` visibility booleans. |
| `activation_changed` | `value` and `previous` keyboard activation booleans. |

Read the current values through `ui.surface.width`, `height`, `screen`,
`scale`, `safe_area`, `visible` and `active`. These are snapshots, not reactive
bindings. Monitor descriptions include `name`, `geometry` and
`available_geometry`; a platform may also provide `id`. Monitor rectangles
use desktop logical coordinates. `scale` converts logical sizes to backing
pixel sizes.

Safe areas contain `top`, `left`, `right`, `bottom` and `exclusions`.
Exclusions are rectangles in surface coordinates. On macOS, native screen
safe areas and the two unobstructed regions beside the notch determine these
rectangles. A surface below the notch has no intersecting exclusion. The
conservative top margin can cover the entire notch band; use exclusion
rectangles to retain space on either side. Other platforms use Qt's safe
margins when available.

## Lifecycle and reload

`mount` runs after a successful generation activates. `unmount` runs while
its handles are still valid, before its subscriptions, I/O and objects are
destroyed. Both can be registered on elements or `ui.surface` and do not
propagate. Mount means the UI generation exists; native visibility is a
separate state. Mount is not delivered retroactively to handlers registered
after activation; construction is the place to register lifecycle handlers.

Rejected candidates never mount or unmount. A successful reload cancels the
previous generation's active pointers, delivers its unmount handlers and
then mounts the replacement. Native cleanup runs even if a Lua callback
fails. Focus and local input state do not survive a reload automatically.
