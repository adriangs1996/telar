import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading


interface_xml = '''<node>
  <interface name="org.freedesktop.Notifications">
    <method name="GetCapabilities"><arg type="as" direction="out"/></method>
    <method name="GetServerInformation">
      <arg type="s" direction="out"/><arg type="s" direction="out"/>
      <arg type="s" direction="out"/><arg type="s" direction="out"/>
    </method>
    <method name="Notify">
      <arg type="s" direction="in"/><arg type="u" direction="in"/>
      <arg type="s" direction="in"/><arg type="s" direction="in"/>
      <arg type="s" direction="in"/><arg type="as" direction="in"/>
      <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
      <arg type="u" direction="out"/>
    </method>
    <method name="CloseNotification"><arg type="u" direction="in"/></method>
  </interface>
</node>'''

command_timeout_ms = 3000
process_slack_ms = 2000
process_wait_seconds = 10


def serve(binary, output):
    from gi.repository import Gio, GLib

    notices = []
    pending = []
    loop = GLib.MainLoop()
    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    interface = Gio.DBusNodeInfo.new_for_xml(interface_xml).interfaces[0]

    def dispatch(*call):
        sender_connection, sender, object_path, interface_name, method, parameters, invocation = call
        if method == 'GetCapabilities':
            invocation.return_value(GLib.Variant('(as)', (['body'],)))
        elif method == 'GetServerInformation':
            invocation.return_value(GLib.Variant('(ssss)', ('Telar fixture', 'telar', '1', '1.2')))
        elif method == 'CloseNotification':
            invocation.return_value(None)
        elif method == 'Notify':
            application, replaced, icon, title, message, actions, hints, expiry = parameters.unpack()
            notices.append(dict(application=application, title=title, message=message, expiry=expiry))
            if title == 'Hold reply':
                pending.append(invocation)
            else:
                invocation.return_value(GLib.Variant('(u)', (len(notices),)))

    registration = connection.register_object('/org/freedesktop/Notifications', interface, dispatch, None, None)
    reply = connection.call_sync(
        'org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
        GLib.Variant('(su)', ('org.freedesktop.Notifications', 0)), GLib.VariantType.new('(u)'),
        Gio.DBusCallFlags.NONE, command_timeout_ms, None,
    )
    assert reply.unpack()[0] == 1
    thread = threading.Thread(target=loop.run)
    thread.start()
    cases = [
        ('Telar', 'Body text', 'Telar', 'Body text'),
        ('--app-name=Other', 'Literal title', '--app-name=Other', 'Literal title'),
        ('a"b\\c\n', 'UTF-8: á日🚀\t"quoted"\\end', 'abc', 'UTF-8: á日🚀quotedend'),
        ('Hold reply', 'Deadline test', 'Hold reply', 'Deadline test'),
    ]
    checks = []
    try:
        for title, message, expected_title, expected_message in cases:
            command = [str(binary), 'notify', title, message]
            result = subprocess.run(command, capture_output=True, text=True, timeout=process_wait_seconds)
            report = json.loads(result.stdout)
            checks.append(dict(command=command, exit_code=result.returncode, report=report, stderr=result.stderr))
            assert notices[-1]['title'] == expected_title and notices[-1]['message'] == expected_message
            if title == 'Hold reply':
                assert result.returncode == 1 and report['failure'] == 'timeout'
                assert command_timeout_ms <= report['elapsed_ms'] <= command_timeout_ms + process_slack_ms
            else:
                assert result.returncode == 0 and report['succeeded']
        assert len(notices) == len(cases)
    finally:
        loop.quit()
        thread.join(process_wait_seconds)
        connection.unregister_object(registration)
        connection.close_sync(None)
        record = dict(
            recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
            checks=checks,
            notices=notices,
            scope='Real Qt native notification adapter and installed notify-send against an isolated D-Bus notification service. Checks literal leading-option text, original sanitization, Unicode and the original three-second deadline. Does not post to the user desktop or verify desktop pixels.',
        )
        (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
        assert not thread.is_alive()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--session', action='store_true', help=argparse.SUPPRESS)
    options = parser.parse_args()
    if not sys.platform.startswith('linux'):
        parser.error('This check requires Linux, PyGObject, libnotify and dbus-run-session')
    binary = options.build_dir.resolve() / 'gui-host-effects-smoke'
    output = options.output_dir.resolve()
    if options.session:
        serve(binary, output)
        return
    if not shutil.which('notify-send') or not shutil.which('dbus-run-session'):
        parser.error('notify-send and dbus-run-session must be installed')
    output.mkdir(parents=True, exist_ok=False)
    environment = dict(os.environ)
    environment.pop('DBUS_SESSION_BUS_ADDRESS', None)
    environment.pop('DBUS_STARTER_ADDRESS', None)
    command = ['dbus-run-session', '--', sys.executable, str(Path(__file__).resolve()), '--session', '--build-dir', str(options.build_dir.resolve()), '--output-dir', str(output)]
    process = subprocess.Popen(command, env=environment, start_new_session=True)
    try:
        result = process.wait(timeout=process_wait_seconds * 2)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise
    if result:
        raise subprocess.CalledProcessError(result, command)
    print('Matched four native Linux desktop-service requests, including the real three-second deadline')


if __name__ == '__main__':
    main()
