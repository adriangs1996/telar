"""Owned X11 selection provider for bounded-transfer integration tests."""
import argparse
import ctypes as c
import json
from pathlib import Path
import select
import time

U = c.c_ulong
D = c.c_void_p
base = [('type', c.c_int), ('serial', U), ('send_event', c.c_int), ('display', D)]


class Request(c.Structure):
    _fields_ = base + [(name, U) for name in ('owner', 'requestor', 'selection', 'target', 'property', 'time')]


class Selection(c.Structure):
    _fields_ = base + [(name, U) for name in ('requestor', 'selection', 'target', 'property', 'time')]


class Property(c.Structure):
    _fields_ = base + [(name, U) for name in ('window', 'atom', 'time')] + [('state', c.c_int)]


class Event(c.Union):
    _fields_ = [('type', c.c_int), ('request', Request), ('selection', Selection), ('property', Property), ('padding', c.c_long * 24)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--ready', type=Path, required=True)
    parser.add_argument('--mode', choices=('direct', 'incr', 'prefix-failure', 'prefix-stall', 'incr-empty', 'incr-format', 'unannounced', 'declared', 'refused', 'owner-change'), default='incr')
    parser.add_argument('--chunk-bytes', type=int, default=65536)
    options = parser.parse_args()
    assert 0 < options.chunk_bytes <= 262144
    image = options.input.read_bytes()
    x = c.CDLL('libX11.so.6')
    signatures = {
        'XOpenDisplay': (D, [c.c_char_p]), 'XCloseDisplay': (c.c_int, [D]),
        'XDefaultRootWindow': (U, [D]), 'XCreateSimpleWindow': (U, [D, U, c.c_int, c.c_int, c.c_uint, c.c_uint, c.c_uint, U, U]),
        'XInternAtom': (U, [D, c.c_char_p, c.c_int]), 'XSetSelectionOwner': (c.c_int, [D, U, U, U]),
        'XGetSelectionOwner': (U, [D, U]), 'XSelectInput': (c.c_int, [D, U, c.c_long]),
        'XChangeProperty': (c.c_int, [D, U, U, U, c.c_int, c.c_int, c.POINTER(c.c_ubyte), c.c_int]),
        'XSendEvent': (c.c_int, [D, U, c.c_int, c.c_long, c.POINTER(Event)]),
        'XFlush': (c.c_int, [D]), 'XPending': (c.c_int, [D]), 'XNextEvent': (c.c_int, [D, c.POINTER(Event)]),
        'XConnectionNumber': (c.c_int, [D]),
    }
    for name, (result, arguments) in signatures.items():
        getattr(x, name).restype = result
        getattr(x, name).argtypes = arguments
    display = x.XOpenDisplay(None)
    if not display:
        raise RuntimeError('owned X11 display is unavailable')
    try:
        root = x.XDefaultRootWindow(display)
        owner = x.XCreateSimpleWindow(display, root, 0, 0, 1, 1, 0, 0, 0)
        atom = {name: x.XInternAtom(display, name.encode(), 0) for name in ('CLIPBOARD', 'TARGETS', 'image/png', 'INCR', 'ATOM', 'STRING')}
        x.XSetSelectionOwner(display, atom['CLIPBOARD'], owner, 0)
        x.XFlush(display)
        assert x.XGetSelectionOwner(display, atom['CLIPBOARD']) == owner
        options.ready.write_text(json.dumps(dict(owner=owner, mode=options.mode, input_bytes=len(image))) + '\n')
        pending = {}
        deadline = time.monotonic() + 60
        fd = x.XConnectionNumber(display)

        def change(window, prop, kind, data, form=8):
            if form == 32:
                values = (U * len(data))(*data)
                count = len(data)
            else:
                values = (c.c_ubyte * len(data)).from_buffer_copy(data)
                count = len(data)
            x.XChangeProperty(display, window, prop, kind, form, 0, c.cast(values, c.POINTER(c.c_ubyte)), count)
            x.XFlush(display)

        while time.monotonic() < deadline:
            if not x.XPending(display):
                select.select([fd], [], [], .05)
                continue
            event = Event()
            x.XNextEvent(display, c.byref(event))
            if event.type == 30:
                request = event.request
                prop = request.property or request.target
                accepted = True
                if request.target == atom['TARGETS']:
                    change(request.requestor, prop, atom['ATOM'], [atom['TARGETS'], atom['image/png']], 32)
                elif request.target != atom['image/png'] or options.mode == 'refused':
                    accepted = False
                elif options.mode == 'direct':
                    change(request.requestor, prop, atom['image/png'], image)
                else:
                    x.XSelectInput(display, request.requestor, 1 << 22)
                    minimum = 33554433 if options.mode == 'declared' else (0 if options.mode in ('unannounced', 'incr-empty') else len(image))
                    if options.mode == 'incr-format':
                        change(request.requestor, prop, atom['INCR'], b'bad!')
                    else:
                        change(request.requestor, prop, atom['INCR'], [minimum], 32)
                    pending[(request.requestor, prop)] = 0
                    if options.mode == 'owner-change':
                        replacement = x.XCreateSimpleWindow(display, root, 0, 0, 1, 1, 0, 0, 0)
                        x.XSetSelectionOwner(display, atom['CLIPBOARD'], replacement, 0)
                        x.XFlush(display)
                notification = Event()
                notification.selection = Selection(type=31, display=display, requestor=request.requestor, selection=request.selection, target=request.target, property=prop if accepted else 0, time=request.time)
                x.XSendEvent(display, request.requestor, 0, 0, c.byref(notification))
                x.XFlush(display)
            elif event.type == 28 and event.property.state == 1:
                key = (event.property.window, event.property.atom)
                if key not in pending:
                    continue
                offset = pending[key]
                if options.mode == 'prefix-stall' and offset:
                    continue
                if options.mode == 'prefix-failure' and offset:
                    change(*key, atom['STRING'], b'wrong type')
                    del pending[key]
                    continue
                data = b'' if options.mode == 'incr-empty' else image[offset:offset + options.chunk_bytes]
                change(*key, atom['image/png'], data)
                pending[key] += len(data)
                if not data:
                    del pending[key]
        raise RuntimeError('owned X11 provider watchdog expired')
    finally:
        x.XCloseDisplay(display)


if __name__ == '__main__':
    main()
