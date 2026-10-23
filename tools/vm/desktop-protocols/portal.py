#!/usr/bin/env python3
"""Request a real portal capture and consume a frame from its PipeWire remote."""
import os
from pathlib import Path
import sys
import time
import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
destination = "org.freedesktop.portal.Desktop"
path = "/org/freedesktop/portal/desktop"
responses = {}
context = GLib.MainContext.default()


def response(connection, sender, object_path, interface, signal, parameters, data):
    responses[object_path] = parameters.unpack()


bus.signal_subscribe(destination, "org.freedesktop.portal.Request", "Response", None,
                     None, Gio.DBusSignalFlags.NONE, response, None)


def request(interface, method, parameters):
    result = bus.call_sync(destination, path, interface, method, parameters,
                           GLib.VariantType.new("(o)"), Gio.DBusCallFlags.NONE, 30000, None)
    handle = result.unpack()[0]
    deadline = time.monotonic() + 60
    while handle not in responses and time.monotonic() < deadline:
        while context.pending():
            context.iteration(False)
        time.sleep(.02)
    assert handle in responses, f"No response to {method}"
    status, values = responses.pop(handle)
    assert status == 0, (method, status, values)
    print(f"PASS portal {method}", flush=True)
    return values


if sys.argv[1] == "screenshot":
    result = request("org.freedesktop.portal.Screenshot", "Screenshot",
                     GLib.Variant("(sa{sv})", ("", {"interactive": GLib.Variant("b", False)})))
    from urllib.parse import unquote, urlparse
    image = Path(unquote(urlparse(result["uri"]).path))
    assert image.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
    Path(sys.argv[2]).write_bytes(image.read_bytes())
    print("PASS portal screenshot contains a PNG", flush=True)
elif sys.argv[1] == "screencast":
    interface = "org.freedesktop.portal.ScreenCast"
    session = request(interface, "CreateSession", GLib.Variant("(a{sv})", ({
        "session_handle_token": GLib.Variant("s", f"telar{os.getpid()}"),
    },)))["session_handle"]
    print("SELECT_OUTPUT", flush=True)
    request(interface, "SelectSources", GLib.Variant("(oa{sv})", (session, {
        "types": GLib.Variant("u", 1), "multiple": GLib.Variant("b", False),
        "cursor_mode": GLib.Variant("u", 2),
    })))
    result = request(interface, "Start", GLib.Variant("(osa{sv})", (session, "", {})))
    node, properties = result["streams"][0]
    reply, descriptors = bus.call_with_unix_fd_list_sync(destination, path, interface,
        "OpenPipeWireRemote", GLib.Variant("(oa{sv})", (session, {})),
        GLib.VariantType.new("(h)"), Gio.DBusCallFlags.NONE, 10000, None, None)
    fd = descriptors.get(reply.unpack()[0])
    gi.require_version("Gst", "1.0")
    gi.require_version("GstApp", "1.0")
    gi.require_version("GstVideo", "1.0")
    from gi.repository import Gst, GstApp, GstVideo
    Gst.init(None)
    pipeline = Gst.parse_launch(f"pipewiresrc fd={fd} path={node} do-timestamp=true min-buffers=4 use-bufferpool=false ! videoconvert ! "
                                "video/x-raw,format=RGB ! appsink name=frame sync=false enable-last-sample=false max-buffers=1 drop=true")
    pipeline.set_state(Gst.State.PLAYING)
    deadline = time.monotonic() + 20
    image = b""
    observed = False
    while time.monotonic() < deadline:
        sample = pipeline.get_by_name("frame").emit("try-pull-sample", Gst.SECOND)
        if sample is None:
            message = pipeline.get_bus().timed_pop_filtered(0, Gst.MessageType.ERROR)
            assert message is None, message.parse_error()
            continue
        info = GstVideo.VideoInfo.new_from_caps(sample.get_caps())
        width, height = info.width, info.height
        buffer = sample.get_buffer()
        meta = GstVideo.buffer_get_video_meta(buffer)
        stride = meta.stride[0] if meta else info.stride[0]
        offset = meta.offset[0] if meta else info.offset[0]
        pixels = buffer.extract_dup(0, buffer.get_size())
        if not observed:
            print(f"FRAME {width}x{height} stride={stride} offset={offset} bytes={len(pixels)} flags={int(buffer.get_flags())} max={max(pixels, default=0)}", flush=True)
            observed = True
        if buffer.has_flags(Gst.BufferFlags.GAP | Gst.BufferFlags.CORRUPTED):
            sample = buffer = meta = None
            continue
        image = b"".join(pixels[offset + row * stride:offset + row * stride + width * 3]
                         for row in range(height))
        sample = buffer = meta = None
        if len(image) == width * height * 3 and any(image):
            break
    assert image and len(image) == width * height * 3 and any(image), "PipeWire produced no desktop pixels"
    Path(sys.argv[2]).write_bytes(f"P6\n{width} {height}\n255\n".encode() + image)
    pipeline.set_state(Gst.State.NULL)
    os.close(fd)
    bus.call_sync(destination, session, "org.freedesktop.portal.Session", "Close", None,
                  None, Gio.DBusCallFlags.NONE, 10000, None)
    print(f"PASS PipeWire delivered {width}x{height} video pixels", flush=True)
else:
    raise SystemExit("Expected screenshot or screencast")
