#!/usr/bin/env python3
"""Real GTK clients for drag-and-drop and input-method integration checks."""
import sys
from pathlib import Path
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk

mode = sys.argv[1]
result = Path(sys.argv[2])
window = Gtk.Window(title=f"Telar GTK {mode}")
window.set_default_size(400, 300)
window.connect("destroy", Gtk.main_quit)

if mode == "source":
    widget = Gtk.EventBox()
    widget.add(Gtk.Label(label="Drag this file to the destination"))
    widget.drag_source_set(Gdk.ModifierType.BUTTON1_MASK,
                           [Gtk.TargetEntry.new("text/uri-list", 0, 0)], Gdk.DragAction.COPY)

    widget.connect("drag-begin", lambda *_: print("DRAG_BEGIN", flush=True))
    widget.connect("drag-end", lambda *_: print("DRAG_END", flush=True))

    def provide(widget, context, selection, info, timestamp):
        print("DRAG_DATA_GET", flush=True)
        selection.set_uris(["file:///tmp/telar-drag-test.txt"])

    widget.connect("drag-data-get", provide)
elif mode == "destination":
    widget = Gtk.EventBox()
    widget.add(Gtk.Label(label="Drop a file here"))
    widget.drag_dest_set(Gtk.DestDefaults.ALL,
                         [Gtk.TargetEntry.new("text/uri-list", 0, 0)], Gdk.DragAction.COPY)

    def received(widget, context, x, y, selection, info, timestamp):
        print("DRAG_DATA_RECEIVED", flush=True)
        result.write_text("\n".join(selection.get_uris()))
        Gtk.drag_finish(context, True, False, timestamp)

    widget.connect("drag-data-received", received)
elif mode == "ime":
    widget = Gtk.Entry()
    widget.connect("changed", lambda entry: result.write_text(entry.get_text()))
else:
    raise SystemExit(f"Unknown mode: {mode}")

window.add(widget)
window.show_all()
widget.grab_focus()
Gtk.main()
