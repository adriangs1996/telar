import argparse
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import time

from PIL import Image, ImageChops

from capture_fullscreen_strip import replace_once, sha
from history_capture_proxy import HistoryCaptureProxy


repository = Path(__file__).resolve().parents[3]


def compile_probe(source, output):
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit', '-framework', 'Metal',
                    '-framework', 'QuartzCore', '-I', str(repository / 'tools'), str(source), '-o', str(output)], check=True)


def prepare_probe(output):
    shutil.copy2(__file__, output / 'capture_driver.py')
    shutil.copy2(Path(__file__).with_name('history_capture_proxy.py'), output / 'history_capture_proxy.py')
    tools = repository / 'tools'
    source = (tools / 'gui_actions.m').read_text()
    source = '#import <QuartzCore/QuartzCore.h>\nstatic CFTimeInterval history_last_input_time;\n' + source
    source = replace_once(source, 'if (script == NULL || ![NSProcessInfo.processInfo.arguments containsObject:@"gui"]) return;',
                          'if (script == NULL) return;')
    source = replace_once(source, '@([view desiredPointerShape]), @"native_cursor"',
                          '@([view respondsToSelector:@selector(desiredPointerShape)] ? [view desiredPointerShape] : 0), @"native_cursor"')
    source = replace_once(source, 'charactersIgnoringModifiers:characters', 'charactersIgnoringModifiers:action[@"unmodified"] ?: characters')
    source = replace_once(source, '@property(nonatomic) NSPoint probeLocation;',
                          '@property(nonatomic) NSPoint probeLocation;\n@property(nonatomic, weak) NSWindow *probeWindow;')
    source = replace_once(source, '@implementation TelarScrollProbe', '''@implementation TelarScrollProbe
- (NSWindow *)window { return self.probeWindow; }
- (NSTimeInterval)timestamp { return CACurrentMediaTime(); }
- (NSEventType)type { return NSEventTypeScrollWheel; }
- (CGFloat)deltaX { return 0; }
- (CGFloat)deltaY { return self.probeDelta; }
- (NSUInteger)deviceID { return 0; }
- (BOOL)isDirectionInvertedFromDevice { return NO; }''')
    source = replace_once(source, '''    id control = find_control([view accessibilityChildren], action[@"control"]);
    if (control == nil) abort();
    NSRect frame = [control accessibilityFrame];
    TelarScrollProbe *event = [TelarScrollProbe new];
    event.probeLocation = [view.window convertPointFromScreen:NSMakePoint(NSMidX(frame), NSMidY(frame))];''', '''    TelarScrollProbe *event = [TelarScrollProbe new];
    event.probeWindow = view.window;
    if (action[@"point"]) {
        NSArray *point = action[@"point"];
        CGFloat y = [point[1] doubleValue];
        NSPoint local = NSMakePoint([point[0] doubleValue], view.isFlipped ? y : view.bounds.size.height - y);
        event.probeLocation = [view convertPoint:local toView:nil];
    } else {
        id control = find_control([view accessibilityChildren], action[@"control"]);
        if (control == nil) abort();
        NSRect frame = [control accessibilityFrame];
        event.probeLocation = [view.window convertPointFromScreen:NSMakePoint(NSMidX(frame), NSMidY(frame))];
    }''')
    source = replace_once(source, 'if (action[@"key"]) send_key(view, action);',
                          'if (action[@"key"] || action[@"text"] || action[@"preedit"] || action[@"scroll"]) history_last_input_time = CACurrentMediaTime();\n'
                          '            if (action[@"key"]) send_key(view, action);')
    source = replace_once(source, '[window setContentSize:NSMakeSize([size[0] doubleValue], [size[1] doubleValue])];',
                          'const NSSize requested_size = NSMakeSize([size[0] doubleValue], [size[1] doubleValue]);\n'
                          '                if (!NSEqualSizes(view.bounds.size, requested_size)) {\n'
                          '                    history_last_input_time = CACurrentMediaTime();\n'
                          '                }\n'
                          '                [window setContentSize:requested_size];')
    source = replace_once(source, 'fprintf(stderr, "GUI action %lu: %s\\n", (unsigned long)index, [action.description UTF8String]);',
                          'fprintf(stderr, "History action uptime %.9f\\n", CACurrentMediaTime());\n'
                          '            fprintf(stderr, "GUI action %lu: %s\\n", (unsigned long)index, [action.description UTF8String]);')
    source = replace_once(source, 'if (type.unsignedIntegerValue == NSEventTypeKeyDown) [view keyDown:event];\n        else [view keyUp:event];',
                          '[NSApp postEvent:event atStart:NO];')
    source = replace_once(source, 'if (action[@"text"]) [(id<NSTextInputClient>)view insertText:action[@"text"] replacementRange:NSMakeRange(NSNotFound, 0)];',
                          'if (action[@"text"]) [(id<NSTextInputClient>)view insertText:action[@"text"] replacementRange:NSMakeRange(NSNotFound, 0)];\n'
                          '            if (action[@"preedit"]) [(id<NSTextInputClient>)view setMarkedText:action[@"preedit"] selectedRange:NSMakeRange([action[@"preedit"] length], 0) replacementRange:NSMakeRange(NSNotFound, 0)];')
    native_context = r'''static NSDictionary *text_input_record(NSView *view) {
    id<NSTextInputClient> client = (id<NSTextInputClient>)view;
    if (![view respondsToSelector:@selector(selectedRange)] || ![view respondsToSelector:@selector(markedRange)]) return @{};
    NSRange selected = [client selectedRange];
    NSRange marked = [client markedRange];
    NSRange actual = NSMakeRange(NSNotFound, 0);
    const NSUInteger maximum_history_units = 128;
    NSAttributedString *surrounding = [client attributedSubstringForProposedRange:NSMakeRange(0, maximum_history_units) actualRange:&actual];
    return @{@"selected": @[@(selected.location), @(selected.length)], @"marked": @[@(marked.location), @(marked.length)], @"has_marked": @([client hasMarkedText]), @"surrounding": surrounding.string ?: @"", @"actual": @[@(actual.location), @(actual.length)]};
}

'''
    context_position = source.index('static NSDictionary *pointer_record(')
    source = source[:context_position] + native_context + source[context_position:]
    source = replace_once(source, '@"diagrams": diagrams, @"controls": controls,', '@"last_input_time": @(history_last_input_time), @"text_input": text_input_record(view), @"diagrams": diagrams, @"controls": controls,')
    source = replace_once(source, '@"view_points": @[@(view.bounds.size.width), @(view.bounds.size.height)],',
                          '@"view_points": @[@(view.bounds.size.width), @(view.bounds.size.height)],\n'
                          '             @"view_pixels": @[@([view convertRectToBacking:view.bounds].size.width), @([view convertRectToBacking:view.bounds].size.height)],')
    start = source.index('static id initialize(')
    end = source.index('\nstatic NSString *native_cursor', start)
    source = source[:start] + source[end:]
    start = source.index('    const char *color = getenv("TELAR_GUI_MARKER");')
    end = source.index('    dispatch_after(', start)
    source = source[:start] + source[end:]
    (output / 'history_actions.m').write_text(source)
    shutil.copy2(tools / 'gui_view.h', output / 'gui_view.h')
    shutil.copy2(Path(__file__).with_name('history_capture.m'), output / 'history_capture.m')
    compile_probe(output / 'history_actions.m', output / 'actions.dylib')
    compile_probe(output / 'history_capture.m', output / 'capture.dylib')


def commands(command=None):
    values = ['echo TELAR_HISTORY_PIXEL_ONE', "printf '%s\\n' TELAR_HISTORY_PIXEL_TWO",
              "printf '%s\\n' TELAR_HISTORY_PIXEL_THREE\nprintf '%s\\n' second-line\nprintf '%s\\n' third-line"]
    if command is not None:
        values[0] = command
    return '\n'.join(f': {1_200_000_000 + index}:0;' + command.replace('\n', '\\\n')
                     for index, command in enumerate(values)) + '\n'


def script(directory, settings):
    viewport = settings.viewport
    inspecting = settings.inspect
    scope = settings.scope
    failed = settings.failed
    actions = [dict(activate=True, resize=viewport), *([{}] * 10),
               dict(key='\x02', unmodified='b', code=11, ctrl=True), dict(key='/', code=44),
               *([{}] * 5), dict(text=('!' if failed else '') + settings.query), *([{}] * 15)]
    for _ in range(['global', 'workspace', 'cwd', 'pane'].index(scope)):
        actions.extend([dict(key='\t', code=48), *([{}] * 15)])
    for _ in range(['human', 'agent', 'all'].index(settings.author)):
        actions.extend([dict(key='\t', code=48, shift=True), *([{}] * 15)])
    for _ in range(settings.selected_row):
        actions.extend([dict(key='\uf700', code=126), *([{}] * 5)])
    if inspecting:
        actions.extend([dict(key='\x0f', unmodified='o', code=31, ctrl=True), *([{}] * 15)])
    for _ in range(settings.inspection_pages):
        actions.extend([dict(key='\uf72d', code=121), *([{}] * 5)])
    if settings.select_prefix is not None:
        actions.extend([dict(key='\uf729', code=115), *([{}] * 5)])
        for _ in range(settings.select_prefix):
            actions.extend([dict(key='\uf703', code=124, shift=True), *([{}] * 2)])
    if settings.select_all:
        actions.extend([dict(key='a', code=0, cmd=True), *([{}] * 15)])
    for _ in range(settings.left):
        actions.extend([dict(key='\uf702', code=123), *([{}] * 2)])
    if settings.preedit is not None:
        actions.extend([dict(preedit=settings.preedit), *([{}] * 15)])
    if settings.commit is not None:
        actions.extend([dict(text=settings.commit), *([{}] * 15)])
    for event in settings.wheel_events:
        actions.extend([dict(scroll=event['delta'], point=event['point'], discrete=event['discrete'], phase=event['phase']), *([{}] * 5)])
    for _ in range(settings.escape_count):
        actions.extend([dict(key='\x1b', code=53), *([{}] * 5)])
    if settings.refresh_viewport:
        viewport_refresh_step = 1
        actions.extend([dict(resize=[viewport[0] + viewport_refresh_step, viewport[1]]), *([{}] * 5)])
    actions.extend([dict(resize=viewport), *([{}] * 15),
                    dict(record=str(directory / 'native-state.json')), dict(signal=str(directory / 'settled.at'))])
    capture_readback_ticks = 20
    actions.extend([{}] * capture_readback_ticks)
    (directory / 'actions.json').write_text(json.dumps(actions) + '\n')


def float_owned_windows(process, floated):
    if not shutil.which('aerospace'):
        return

    listing = subprocess.check_output(['aerospace', 'list-windows', '--all', '--format', '%{window-id} %{app-pid}'], text=True, timeout=5)
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1] == str(process.pid) and fields[0] not in floated:
            result = subprocess.run(['aerospace', 'layout', '--window-id', fields[0], 'floating'], capture_output=True, timeout=5)
            if result.returncode == 0:
                floated.append(fields[0])


def capture(kind, binary, cpp_gui, output, settings):
    directory = output / kind
    directory.mkdir()
    (directory / 'frames').mkdir()
    script(directory, settings)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('TELAR_', 'BENCH_')) and key not in ['DYLD_INSERT_LIBRARIES', 'QT_QUICK_BACKEND']}
    environment.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
                       TELAR_SOCKET_PATH=str(directory / 'runtime.sock'), XDG_DATA_HOME=str(directory / 'data'),
                       XDG_CONFIG_HOME=str(directory / 'config'), QT_QPA_PLATFORM='cocoa', QSG_RHI_BACKEND='metal')
    config = output / 'gui.lua'
    shutdown_grace_seconds = 5
    smoke_milliseconds = int((settings.capture_timeout + shutdown_grace_seconds) * 1000)
    command = [str(binary), 'gui', '--config', str(config), '/bin/sh'] if kind == 'zig' else [str(cpp_gui), '--fresh', '--config', str(config), '--smoke-ms', str(smoke_milliseconds), '/bin/sh']
    runtime_configuration = ['--config', str(config)] if getattr(settings, 'runtime_configuration', False) else ['--no-config']
    subprocess.run([str(binary), 'server', '--background', *runtime_configuration], env=environment, cwd=output / 'work', check=True)
    process = None
    proxy = None
    try:
        if not settings.empty_history:
            subprocess.run([str(binary), 'history', 'import', 'zsh', '--file', str(output / 'fixture.zsh_history')],
                           env=environment, cwd=output / 'work', check=True)
        injected = str(output / 'actions.dylib') + ':' + str(output / 'capture.dylib')
        launch = dict(environment, DYLD_INSERT_LIBRARIES=injected, TELAR_GUI_ACTIONS=str(directory / 'actions.json'),
                      TELAR_HISTORY_CAPTURE=str(directory / 'window.png'), TELAR_HISTORY_CAPTURE_TRIGGER=str(directory / 'settled.at'),
                      TELAR_HISTORY_CAPTURE_STATE=str(directory / 'native-state.json'))
        if settings.history_response != 'normal':
            proxy = HistoryCaptureProxy(environment['TELAR_SOCKET'], directory, settings.history_response, settings.query)
            endpoint = str(proxy.start())
            launch.update(TELAR_SOCKET=endpoint, TELAR_SOCKET_PATH=endpoint)
        floated = []
        started = time.monotonic()
        with (directory / 'launch.log').open('w') as log:
            process = subprocess.Popen(command, env=launch, cwd=output / 'work', stdout=log, stderr=subprocess.STDOUT)
            while process.poll() is None and time.monotonic() - started < settings.capture_timeout:
                float_owned_windows(process, floated)
                time.sleep(.05)
                if (directory / 'window.png.json').is_file() and (directory / 'settled.at').is_file():
                    break

        if not (directory / 'settled.at').is_file():
            raise RuntimeError(f'{kind}: history actions did not settle (process exit: {process.poll()}); inspect {directory}')
        if process.poll() not in [None, 0]:
            raise RuntimeError(f'Qt history capture did not exit successfully: {process.poll()}')
        if not (directory / 'window.png.json').is_file():
            raise RuntimeError(f'{kind}: no presented drawable was captured')

        state = json.loads((directory / 'native-state.json').read_text())
        if state.get('view_points') != settings.viewport:
            raise RuntimeError(f"{kind}: requested viewport {settings.viewport}, received {state.get('view_points')}")
        if not state.get('app_active') or not state.get('window_key'):
            raise RuntimeError(f'{kind}: application or capture window lost native focus')
        if proxy is not None:
            record = proxy.record()
            if not any(query['intercepted'] for query in record['queries']):
                raise RuntimeError(f'{kind}: the requested history fault was not exercised')
            if settings.history_response == 'replacement-loading' and not record['responses']:
                raise RuntimeError(f'{kind}: no page preceded the replacement query')

        return dict(command=command, owned_pid=process.pid, floated_window_ids=floated, native_state=state, proxy=None if proxy is None else proxy.record(), elapsed_seconds=time.monotonic() - started,
                    image_sha256=sha(directory / 'window.png'), frame=json.loads((directory / 'window.png.json').read_text()), recorded_at=time.time())
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        try:
            if proxy is not None:
                proxy.stop()
        finally:
            subprocess.run([str(binary), 'server', 'stop'], env=environment, cwd=output / 'work', timeout=10, check=False)


def compare(output):
    with Image.open(output / 'zig/window.png') as original, Image.open(output / 'qt/window.png') as candidate:
        if original.size != candidate.size:
            raise RuntimeError(f'The captured viewports differ: Zig={original.size}, Qt={candidate.size}')
        difference = ImageChops.difference(original.convert('RGBA'), candidate.convert('RGBA'))
        coverage = difference.getchannel('R')
        for channel in ['G', 'B', 'A']:
            coverage = ImageChops.lighter(coverage, difference.getchannel(channel))

        return dict(size=original.size, compared_pixels=original.width * original.height,
                    different_pixels=original.width * original.height - coverage.histogram()[0], difference_bounds=coverage.getbbox())


def main():
    parser = argparse.ArgumentParser(description='Capture the original and Qt history with identical imported commands and native input')
    parser.add_argument('zig_binary', type=Path)
    parser.add_argument('cpp_gui', type=Path)
    parser.add_argument('output_directory', type=Path)
    parser.add_argument('--viewport', type=int, nargs=2, default=[1180, 720])
    parser.add_argument('--inspect', action='store_true')
    parser.add_argument('--selected-row', type=int, default=0)
    parser.add_argument('--inspection-pages', type=int, default=0)
    parser.add_argument('--fixture-command')
    parser.add_argument('--capture-timeout', type=float, default=35)
    parser.add_argument('--scope', choices=['global', 'workspace', 'cwd', 'pane'], default='global')
    parser.add_argument('--failed', action='store_true')
    parser.add_argument('--query', default='TELAR_HISTORY_PIXEL')
    parser.add_argument('--empty-history', action='store_true')
    parser.add_argument('--author', choices=['human', 'agent', 'all'], default='human')
    parser.add_argument('--history-response', choices=['normal', 'initial-loading', 'replacement-loading', 'error'], default='normal')
    escape = parser.add_mutually_exclusive_group()
    escape.add_argument('--close-history', action='store_true')
    escape.add_argument('--escape', type=int, default=0)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--select-all', action='store_true')
    selection.add_argument('--select-prefix', type=int)
    parser.add_argument('--left', type=int, default=0)
    parser.add_argument('--preedit')
    parser.add_argument('--commit')
    parser.add_argument('--refresh-viewport', action='store_true')
    parser.add_argument('--wheel-script', type=Path)
    options = parser.parse_args()
    options.wheel_events = [] if options.wheel_script is None else json.loads(options.wheel_script.read_text())
    if not isinstance(options.wheel_events, list):
        parser.error('Wheel script must contain a list of events')
    for event in options.wheel_events:
        if not isinstance(event, dict) or set(event) != {'delta', 'point', 'discrete', 'phase'}:
            parser.error('Each wheel event requires delta, point, discrete and phase')
        point = event['point']
        if not isinstance(point, list) or len(point) != 2 or not all(isinstance(value, (int, float)) and math.isfinite(value) for value in [event['delta'], *point]):
            parser.error('Wheel coordinates and delta must be finite numbers')
        if not isinstance(event['discrete'], bool) or event['phase'] not in ['none', 'begin', 'update', 'end', 'cancel']:
            parser.error('Wheel events require a boolean discrete flag and a supported phase')
    if options.escape < 0 or (options.select_prefix is not None and options.select_prefix < 0):
        parser.error('Escape and selection counts must be nonnegative')
    if options.selected_row < 0 or options.inspection_pages < 0:
        parser.error('Row and inspection-page counts must be nonnegative')
    if not 0 < options.capture_timeout < float('inf'):
        parser.error('Capture timeout must be finite and positive')
    if options.inspection_pages and not options.inspect:
        parser.error('Inspection pages require --inspect')
    options.escape_count = 1 if options.close_history else options.escape
    output = options.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / 'work').mkdir()
    (output / 'fixture.zsh_history').write_text('' if options.empty_history else commands(options.fixture_command))
    (output / 'gui.lua').write_text('''return {
  api_version = 2,
  theme = "shade",
  client = { sidebar = { visible = false } },
  gui = {
    font = { family = "JetBrains Mono", size = 15 },
    window = { padding = { x = 0, y = 0 }, background_opacity = 1 },
    cursor = { blink = false },
  },
}
''')
    prepare_probe(output)
    result = dict(scope='Native Cocoa input opens the same history query in both actual GUIs. Both captures retain a Metal drawable after its presentation callback and copy it in a separate readback submission. This records pixel differences; it does not assert complete visual or performance parity.', empty_history=options.empty_history, selected_author=options.author, history_response=options.history_response,
                  binary_sha256=dict(zig=sha(options.zig_binary), qt=sha(options.cpp_gui)), fixture_sha256=sha(output / 'fixture.zsh_history'), inspecting=options.inspect, selected_row=options.selected_row, inspection_pages=options.inspection_pages, selected_scope=options.scope, failed_only=options.failed, query=options.query, select_all=options.select_all, cursor_left=options.left, preedit=options.preedit, commit=options.commit, select_prefix=options.select_prefix, escape_count=options.escape_count, refresh_viewport=options.refresh_viewport, wheel_events=options.wheel_events, clients={})
    try:
        for kind in ['zig', 'qt']:
            result['clients'][kind] = capture(kind, options.zig_binary.resolve(), options.cpp_gui.resolve(), output, options)
            print('Captured', kind, flush=True)
        result['comparison'] = compare(output)
    finally:
        result['source_sha256'] = {str(path): sha(path) for path in [Path(__file__), output / 'capture_driver.py', output / 'history_actions.m', output / 'history_capture.m', output / 'gui_view.h', output / 'gui.lua']}
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result['comparison']), flush=True)


if __name__ == '__main__':
    main()
