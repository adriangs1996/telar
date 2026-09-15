# Native new-context form

Validated on macOS on 2026-09-15 using the local working tree.

The GUI form uses a rounded panel, proportional labels, padded text fields,
folder rows and explicit Cancel/Create actions. Its layout follows chrome pixel
metrics. Fields stay in place when asynchronous suggestions arrive. The input
text keeps the existing monospace editor with its own chrome-sized metrics;
selection and IME caret coordinates include the field padding.

## Captures

These are screen captures of the running Metal application, bounded around its
published accessibility controls. They are not mockups.

| State | Osaka Jade, font size 15 | Vesper, font size 22 |
| --- | --- | --- |
| Empty | [Capture](osaka-jade-empty.png) | [Capture](vesper-empty.png) |
| Folder suggestions | [Capture](osaka-jade-folders.png) | [Capture](vesper-folders.png) |
| Create missing folder | [Capture](osaka-jade-confirmation.png) | [Capture](vesper-confirmation.png) |

## Verification

```sh
zig build
zig build test-gui test-client check-client-boundaries codestyle --summary all
python3 tools/gui_context_form.py zig-out/bin/telar /tmp/telar-form-review
```

The test directory must not already exist. The native check creates an isolated
runtime, exercises real pointer clicks located through accessibility, verifies
folder completion, confirms creation of a missing directory, checks the new
shell's cwd, and closes a fresh form through its close button. It stops the
isolated runtime in `finally`.

[Checks](checks.log): 346 GUI tests and 902 client tests passed; client boundaries
and code style passed. Coverage includes tiny pixel viewports, geometry independent
of terminal spacing, stable field positions, warm drawing without allocations,
button release cancellation, stale generations/listings, fractional scrolling,
native accessibility actions, Unicode input and IME caret placement.

[Native results](native.log): both theme/font configurations passed. Linux host
interaction and rendering were not exercised in this run.

The native check also exposed a pre-existing outbox omission: workspace creation
lost `create_cwd` while queued. The owned request now preserves the flag through
encoding, with a regression test for both confirmed and unconfirmed requests.
