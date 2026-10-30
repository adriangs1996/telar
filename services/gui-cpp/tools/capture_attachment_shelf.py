import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import uuid

from PIL import Image

import capture_history as capture
from capture_provider_marks import interpreter_image

repository = Path(__file__).resolve().parents[3]
service = repository / 'services/gui-cpp'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def agent_source():
    return '''import json, os, subprocess, sys, termios, tty
from pathlib import Path
output = Path(sys.argv[1])
binary = os.environ['TELAR_BIN_PATH']
endpoint = os.environ['TELAR_SOCKET_PATH']
result = subprocess.run([binary, 'hook', 'claude', '--socket', endpoint], input=json.dumps(dict(hook_event_name='SessionStart', cwd=os.getcwd(), session_id='attachment-fixture', session_title='Image prompt')), text=True, capture_output=True, timeout=10)
(output / 'hook.json').write_text(json.dumps(dict(exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr)))
assert result.returncode == 0
previous = termios.tcgetattr(0)
try:
    tty.setraw(0)
    os.write(1, b'\\x1b[2J\\x1b[HImage capture fixture\\r\\n\\r\\nPaste an image: ')
    (output / 'agent-ready.at').touch()
    with (output / 'input.bin').open('wb', buffering=0) as journal:
        while True:
            value = os.read(0, 1)
            if not value:
                break
            journal.write(value)
            if value == b'\\x16':
                os.write(1, b'[Image #1]')
                (output / 'agent-pasted.at').touch()
finally:
    termios.tcsetattr(0, termios.TCSANOW, previous)
'''


def actions(directory, settings):
    command = shlex.join([str(settings.agent), str(settings.output / 'agent.py'), str(directory)])
    values = [dict(activate=True, resize=settings.viewport), *([{}] * 10), dict(pointer='enter', point=[800, 300], warp_pointer=True), dict(pointer='move', point=[800, 301]), dict(text='exec ' + command + '\n'), dict(wait=str(directory / 'agent-ready.at'), wait_seconds=15), *([{}] * 15), dict(key='\x16', unmodified='v', code=9, ctrl=True), dict(wait=str(directory / 'agent-pasted.at'), wait_seconds=15), *([{}] * 20)]
    if settings.mode != 'shelf':
        if not settings.bare_click:
            values += [dict(pointer='enter', point=[388, 562], warp_pointer=True), dict(pointer='move', point=[389, 562]), *([{}] * 5)]
        values += [dict(click=[388 / settings.viewport[0], 562 / settings.viewport[1]]), *([{}] * 15), dict(key='x', code=7), *([{}] * 5)]
        if settings.mode in ('restored', 'rehover'):
            values += [dict(key='\x1b', code=53), *([{}] * 10), dict(key='z', code=6), *([{}] * 10)]
    if settings.mode == 'rehover':
        values += [dict(pointer='enter', point=[388, 562], warp_pointer=True), dict(pointer='move', point=[389, 562]), *([{}] * 15)]
    values += [dict(resize=[settings.viewport[0] + 1, settings.viewport[1]]), *([{}] * 5), dict(resize=settings.viewport), *([{}] * 15)]
    values += [dict(record=str(directory / 'native-state.json')), dict(signal=str(directory / 'settled.at')), *([{}] * 20)]
    (directory / 'actions.json').write_text(json.dumps(values) + '\n')


def prepare_pointer_probe(output):
    path = output / 'history_actions.m'
    source = path.read_text()
    before = '    if (action[@"control"]) {'
    after = '''    if (action[@"point"]) {
        NSArray *point = action[@"point"];
        NSPoint local = NSMakePoint([point[0] doubleValue], view.isFlipped ? [point[1] doubleValue] : view.bounds.size.height - [point[1] doubleValue]);
        location = [view convertPoint:local toView:nil];
    } else if (action[@"control"]) {'''
    source = capture.replace_once(source, before, after)
    before = '    saved_location = location;'
    after = '''    if ([action[@"warp_pointer"] boolValue]) {
        const NSPoint screen = [view.window convertPointToScreen:location];
        const CGFloat desktop_top = NSMaxY(NSScreen.screens.firstObject.frame);
        if (CGWarpMouseCursorPosition(CGPointMake(screen.x, desktop_top - screen.y)) != kCGErrorSuccess) abort();
        fprintf(stderr, "Warped owned window pointer: target=%.3f,%.3f actual=%.3f,%.3f\\n", screen.x, screen.y, NSEvent.mouseLocation.x, NSEvent.mouseLocation.y);
    }
    saved_location = location;'''
    source = capture.replace_once(source, before, after)
    before = '    if (type == NSEventTypeMouseEntered) [view mouseEntered:event];'
    after = '''    id tracking_target = view;
    const NSTrackingAreaOptions desired = type == NSEventTypeMouseMoved ? NSTrackingMouseMoved : NSTrackingMouseEnteredAndExited;
    if (type == NSEventTypeMouseMoved || type == NSEventTypeMouseEntered || type == NSEventTypeMouseExited) {
        for (NSTrackingArea *area in view.trackingAreas) {
            if ((area.options & desired) != 0 && area.owner != nil) {
                tracking_target = area.owner;
                break;
            }
        }
        fprintf(stderr, "Native tracking delivery: view=%s target=%s type=%lu\\n", NSStringFromClass(view.class).UTF8String, NSStringFromClass([tracking_target class]).UTF8String, (unsigned long)type);
    }
    if (type == NSEventTypeMouseEntered) [tracking_target mouseEntered:event];'''
    source = capture.replace_once(source, before, after)
    source = source.replace('[view mouseExited:event]', '[tracking_target mouseExited:event]').replace('[view mouseMoved:event]', '[tracking_target mouseMoved:event]')
    source = source.replace('modifierFlags:flags timestamp:0', 'modifierFlags:flags timestamp:CACurrentMediaTime()')
    source = capture.replace_once(source, 'if (action[@"pointer"]) send_pointer(view, action);', 'if (action[@"pointer"]) { history_last_input_time = CACurrentMediaTime(); send_pointer(view, action); }')
    path.write_text(source)
    capture.compile_probe(path, output / 'actions.dylib')


def main():
    parser = argparse.ArgumentParser(description='Capture actual Zig and Qt clipboard shelves with an owned agent, runtime and private pasteboard')
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--gui', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=('shelf', 'modal', 'restored', 'rehover'), default='shelf')
    parser.add_argument('--bare-click', action='store_true', help='Keep the last observed motion away from the card before delivering its click')
    options = parser.parse_args()
    output = options.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    (output / 'work').mkdir()
    sources = output / 'harness-source'
    sources.mkdir()
    for source in (Path(__file__), service / 'tools/capture_history.py', service / 'tools/attachment_private_clipboard.m', service / 'tools/attachment_clipboard_fixture.m'):
        shutil.copy2(source, sources / source.name)

    helper = output / 'clipboard-fixture'
    library = output / 'clipboard.dylib'
    for source, destination, extra in [('attachment_clipboard_fixture.m', helper, []), ('attachment_private_clipboard.m', library, ['-dynamiclib'])]:
        subprocess.run(['clang', '-fobjc-arc', *extra, '-framework', 'AppKit', str(service / 'tools' / source), '-o', str(destination)], check=True)
    agent = output / 'claude'
    shutil.copy2(interpreter_image(), agent)
    subprocess.run(['codesign', '--force', '--sign', '-', str(agent)], check=True)
    subprocess.run([str(agent), '--version'], check=True)
    (output / 'agent.py').write_text(agent_source())
    image = Image.new('RGBA', (96, 64))
    for y in range(image.height):
        for x in range(image.width):
            image.putpixel((x, y), ((x * 17) % 256, (y * 23) % 256, ((x + y) * 13) % 256, 255))
    incoming = output / 'input.png'
    image.save(incoming)
    board = 'telar-attachment-fixture-' + str(uuid.uuid4())
    reference, gui = options.reference.resolve(), options.gui.resolve()
    record = dict(mode=options.mode, bare_click=options.bare_click, scope='Native actual-client shelf comparison; private pasteboard and owned runtime/agent only. No global acceptance implied.', binary_sha256={str(path): sha(path) for path in (reference, gui)}, board=board, input_sha256=sha(incoming), clients={})
    (output / 'gui.lua').write_text('return {api_version=2,theme="shade",client={sidebar={visible=true}},gui={font={family="JetBrains Mono",size=15},cursor={blink=false},window={padding={x=0,y=0},background_opacity=1}}}\n')
    settings = SimpleNamespace(mode=options.mode, bare_click=options.bare_click, output=output, agent=agent, viewport=[900, 650], capture_timeout=40, empty_history=True, history_response='normal', runtime_configuration=True, extra_environment=dict(TELAR_ATTACHMENT_TEST_BOARD=board), injected_libraries=[str(library)])
    manager = shutil.which('aerospace')
    if manager is not None:
        query = subprocess.run([manager, 'list-windows', '--all', '--json'], capture_output=True, text=True, timeout=5)
        record['window_manager'] = dict(command=query.args, exit_code=query.returncode, stderr=query.stderr)
        if query.returncode != 0:
            if "Can't connect to AeroSpace server" not in query.stderr:
                query.check_returncode()
            capture.float_owned_windows = lambda process, floated: None
    else:
        record['window_manager'] = dict(scope='Optional window manager CLI absent; native viewport/active/key-window assertions remain mandatory.')
    capture.prepare_probe(output)
    prepare_pointer_probe(output)
    capture.script = actions
    try:
        subprocess.run([str(helper), 'write', board, str(incoming)], check=True)
        with tempfile.TemporaryDirectory(prefix='.av-', dir=repository) as temporary:
            for kind in ('zig', 'qt'):
                endpoint = str(Path(temporary) / (kind + '.sock'))
                settings.extra_environment.update(TELAR_SOCKET=endpoint, TELAR_SOCKET_PATH=endpoint)
                record['clients'][kind] = capture.capture(kind, reference, gui, output, settings)
                observed = (output / kind / 'input.bin').read_bytes()
                assert observed == (b'\x16z' if options.mode in ('restored', 'rehover') else b'\x16'), (kind, observed)
                print('Captured', kind, flush=True)
        assert all(sha(path) == record['binary_sha256'][str(path)] for path in (reference, gui))
        record['comparison'] = capture.compare(output)
    finally:
        cleanup = subprocess.run([str(helper), 'clear', board], capture_output=True)
        record['clipboard_cleanup_exit'] = cleanup.returncode
        record['source_sha256'] = {str(path.relative_to(repository)): sha(path) for path in [Path(__file__), service / 'tools/capture_history.py', service / 'tools/attachment_private_clipboard.m', service / 'tools/attachment_clipboard_fixture.m']}
        (output / 'results.json').write_text(json.dumps(record, indent=2) + '\n')
        cleanup.check_returncode()
    print(json.dumps(record['comparison']))


if __name__ == '__main__':
    main()
