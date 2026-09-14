"""Exercises the actual AT-SPI D-Bus bridge in an isolated session bus."""
import os
import subprocess
import sys
import time
from pathlib import Path

import pyatspi
from gi.repository import Gio, GLib


def helper(name):
    return next(str(path) for directory in ("/usr/libexec", "/usr/lib") if (path := Path(directory, name)).is_file())


# Start session services as the test user. This also works on hosts whose
# D-Bus activation policy restricts service execution from SSH sessions.
launcher = subprocess.Popen([helper("at-spi-bus-launcher"), "--launch-immediately"])
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    owned = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", GLib.Variant("(s)", ("org.a11y.Bus",)), None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
    if owned:
        break
    time.sleep(0.02)
assert owned, "AT-SPI bus launcher did not start"
address = bus.call_sync("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress", None, None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
os.environ["AT_SPI_BUS_ADDRESS"] = address
registry = subprocess.Popen([helper("at-spi2-registryd")], env=os.environ)
accessibility_bus = Gio.DBusConnection.new_for_address_sync(address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    registered = accessibility_bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", GLib.Variant("(s)", ("org.a11y.atspi.Registry",)), None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
    if registered:
        break
    time.sleep(0.02)
assert registered, "AT-SPI registry did not start"
process = subprocess.Popen([sys.argv[1], "--serve"], env={**os.environ, "NO_AT_BRIDGE": "0"})
try:
    deadline = time.monotonic() + 12
    app = None
    while time.monotonic() < deadline:
        desktop = pyatspi.Registry.getDesktop(0)
        app = next((child for child in desktop if child.name == "Telar" and child.childCount), None)
        if app is not None:
            break
        if process.poll() is not None:
            raise AssertionError("AT-SPI application exited before registration")
        time.sleep(0.05)
    assert app is not None, "AT-SPI application did not register"
    group = app[0]
    assert group.name == "Content" and group.childCount == 2
    field, button = group[0], group[1]
    assert field.name == "Name" and field.getRole() == pyatspi.ROLE_ENTRY
    text = field.queryText()
    assert text.getText(0, -1) == "a界b" and text.characterCount == 3
    assert text.getSelection(0) == (1, 2)
    assert text.setSelection(0, 1, 2)
    editable = field.queryEditableText()
    assert editable.setTextContents("新 name")
    assert editable.copyText(1, 2)
    assert editable.cutText(1, 2)
    assert editable.pasteText(2)
    assert field.queryComponent().grabFocus()
    action = button.queryAction()
    assert action.getName(0) == "press" and action.doAction(0)
    assert process.wait(timeout=10) == 0
finally:
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
    registry.terminate()
    launcher.terminate()
    registry.wait(timeout=5)
    launcher.wait(timeout=5)
