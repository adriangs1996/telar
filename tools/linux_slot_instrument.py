#!/usr/bin/env python3
"""Instrument copies of native sources, preserving production and recording hashes.

Usage: python3 tools/linux_slot_instrument.py SOURCE_ROOT ISOLATED_COPY_ROOT
Copy the repository first; then build ISOLATED_COPY_ROOT normally. Preload
linux_slot_probe.so at runtime to consume the hooks. Exact anchors fail closed
when the source changes and needs review.
"""
import argparse
import hashlib
import json
from pathlib import Path


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise ValueError(f"Expected one instrumentation anchor: {before!r}")
    return source.replace(before, after)


HOOKS = r'''#pragma once
#include <dlfcn.h>
#include <stdint.h>

static void telar_probe(uint32_t kind, uint64_t token, uint64_t detail) {
    typedef void (*hook)(uint32_t, uint64_t, uint64_t);
    static hook event;
    static int resolved;
    if (!resolved) {
        event = (hook)dlsym(RTLD_DEFAULT, "telar_slot_probe_event");
        resolved = 1;
    }
    if (event) {
        event(kind, token, detail);
    }
}
'''


def instrument_window(source):
    source = replace_once(source, '#include "frame_clock.h"', '#include "frame_clock.h"\n#include "slot_probe_hooks.h"')
    source = replace_once(source, '} window;\n', '''} window;

static void probe_state(const window *self) {
    uint64_t flags = (self->configured ? 1 : 0) | (self->dirty ? 2 : 0) |
                     (self->in_flight ? 4 : 0) | (self->clock.callback ? 8 : 0) |
                     (self->closing ? 16 : 0);
    telar_probe(0, flags, (uint64_t)self->clock.next_draw_ns);
}
''')
    source = replace_once(source, 'static void draw(window *self) {', 'static void draw(window *self) {\n    probe_state(self);')
    source = replace_once(source, '    self->callbacks.render(self->context, viewport, &frame);', '''    probe_state(self);
    telar_probe(1, 0, 0);
    self->callbacks.render(self->context, viewport, &frame);
    telar_probe(2, frame.token, frame.quad_count);''')
    source = replace_once(source, '    self->in_flight = true;\n', '''    self->in_flight = true;
    telar_probe(3, frame.token, 0);
    probe_state(self);
''')
    source = replace_once(source, 'static void destroy(window *self) {', '''static void destroy(window *self) {
    probe_state(self);
    telar_probe(7, 0, 0);''')
    source = replace_once(source, '        int ready = poll(fds, 4, timeout);', '''        probe_state(&self);
        int ready = poll(fds, 4, timeout);''')
    source = replace_once(source, '        telar_input_dispatch(self.input);', '''        probe_state(&self);
        telar_input_dispatch(self.input);''')
    source = replace_once(source, '''                self.in_flight = false;
                callbacks->complete(context, token, outcome == TELAR_RENDER_DELIVERED);''', '''                telar_probe(4, token, outcome);
                self.in_flight = false;
                callbacks->complete(context, token, outcome == TELAR_RENDER_DELIVERED);
                probe_state(&self);''')
    return source


def instrument_worker(source):
    source = replace_once(source, '#include "frame_worker.h"', '#include "frame_worker.h"\n#include "slot_probe_hooks.h"')
    source = replace_once(source, '''        enum telar_render_result result = telar_renderer_draw(self->renderer, viewport, &frame);''', '''        telar_probe(5, frame.token, 0);
        enum telar_render_result result = telar_renderer_draw(self->renderer, viewport, &frame);
        telar_probe(6, frame.token, result);''')
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("copy_root", type=Path)
    args = parser.parse_args()
    source_root, copy_root = args.source_root.resolve(), args.copy_root.resolve()
    if source_root == copy_root:
        parser.error("Instrumentation requires a separate source copy")
    destination = copy_root / "src/gui/linux"
    destination.mkdir(parents=True, exist_ok=True)
    manifest = {"source_root": str(source_root), "copy_root": str(copy_root), "files": {}}
    for name, instrument in (("window.c", instrument_window), ("frame_worker.c", instrument_worker)):
        original = (source_root / "src/gui/linux" / name).read_bytes()
        changed = instrument(original.decode()).encode()
        (destination / name).write_bytes(changed)
        manifest["files"][name] = {
            "original_sha256": hashlib.sha256(original).hexdigest(),
            "instrumented_sha256": hashlib.sha256(changed).hexdigest(),
        }
    (destination / "slot_probe_hooks.h").write_text(HOOKS)
    (copy_root / "linux-slot-instrumentation.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
