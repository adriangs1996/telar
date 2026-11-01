#!/usr/bin/env python3
"""Exercise a relocated preview with a disposable runtime, through LaunchServices."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time


def wait_for(read, predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while True:
        value = read()
        if predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise TimeoutError(f'condition not reached; last value: {value!r}')
        time.sleep(.1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--discover-runtime', action='store_true', help='Exercise bundled CLI endpoint discovery and default XDG config')
    parser.add_argument('--plugins', action='store_true', help='Execute a private plugin through the exact bundled GUI and CLI')
    parser.add_argument('--components', action='store_true', help='Render custom widgets and execute a bar command through the bundled native helper')
    parser.add_argument('--windows', action='store_true', help='Verify two simultaneous GUI instances on the private runtime')
    parser.add_argument('--reference-runtime', type=Path, help='Use this reference runtime/CLI only in disposable test state; the GUI and plugin worker stay bundled')
    args = parser.parse_args()
    original = args.bundle.resolve()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    record = dict(scope='Relocated Release bundle, Cocoa/Metal, private runtime; protocol smoke, not full daily acceptance',
                  runtime_discovery=args.discover_runtime, plugin_execution=args.plugins,
                  custom_components=args.components, concurrent_windows=args.windows, commands=[], processes=[])
    server = direct = finder = concurrent = None
    with tempfile.TemporaryDirectory(prefix='cpp-daily-', dir='/tmp') as temporary:
        state = Path(temporary)
        bundle = state / 'Relocated Preview.app'
        shutil.copytree(original, bundle, symlinks=True)
        bundled_cli = bundle / 'Contents/Resources/bin/telar'
        runtime = args.reference_runtime.resolve() if args.reference_runtime else bundled_cli
        record['runtime_executable'] = str(runtime)
        record['runtime_sha256'] = hashlib.sha256(runtime.read_bytes()).hexdigest()
        record['bundled_cli_sha256'] = hashlib.sha256(bundled_cli.read_bytes()).hexdigest()
        launcher = bundle / 'Contents/MacOS/TelarPreview'
        record['bundled_gui_sha256'] = hashlib.sha256((bundle / 'Contents/MacOS/telar-gui').read_bytes()).hexdigest()
        runtime_directory = state / 'run'
        runtime_directory.mkdir(mode=0o700)
        (runtime_directory / 'telar').mkdir(mode=0o700)
        socket = runtime_directory / 'telar/runtime.sock' if args.discover_runtime else state / 'runtime.sock'
        configuration = state / 'config/telar/config.lua'
        configuration.parent.mkdir(parents=True, mode=0o700)
        if args.plugins:
            package = configuration.parent / 'example'
            package.mkdir(mode=0o700)
            (package / 'plugin.json').write_text(json.dumps(dict(
                api_version=1, id='bundle-smoke', version='1', entry='main.lua',
                source=dict(url='fixture', revision='1'), actions=['toggle'], capabilities=[])))
            (package / 'main.lua').write_text(
                'local t=require("telar");return {actions={toggle=function()return t.action.toggle_sidebar()end}}')
            configuration.write_text("return {api_version=2,plugins={{path='example'}}}\n")
        else:
            configuration.write_text('return {api_version=2}\n')
        component_marker = state / 'bar-command-ready'
        if args.components:
            plugins = "plugins={{path='example'}}," if args.plugins else ''
            configuration.write_text("local t=require('telar');local ui=t.ui;return {api_version=2," + plugins + "client={" +
                "keybindings={t.bind_global({'alt+u'},t.action.open_panel('usage')),t.bind_global({'alt+o'},t.action.pick('mode'))}," +
                "bars={bottom={left=t.bar.static(ui.group({on_click=t.action.open_panel('usage'),ui.label('Daily λ'),ui.badge({text='C++'})})),center=t.bar.tabs()," +
                "right=t.bar.command({command={'/bin/sh','-c','printf ready > \"$1\"; printf \"á λ\"','surface-smoke'," + json.dumps(str(component_marker)) + "},every_ms=60000})}," +
                "top={right=t.bar.dynamic({every_ms=60000,render=function(ctx)return ui.clock('%H:%M')end})}}," +
                "panels={usage=t.panel({render=function(ctx)return {ui.heading('Usage λ'),ui.meter_row({label='Session',value=.5}),ui.actions({ui.button({text='Close',action=t.action.close_panel()})})}end})}," +
                "picks={mode=t.pick({items={'low',{label='High λ',value='high',detail='Daily choice',selected=true}},on_select={'/usr/bin/printf','%s','{}'}})}," +
                "}}\n")
        initial_configuration = configuration.read_bytes()
        home = state / 'home'
        home.mkdir()
        (home / '.zprofile').write_text('export TELAR_CPP_SMOKE_LOGIN=1\n')
        env = {key: os.environ[key] for key in ('USER', 'LOGNAME', 'TMPDIR') if key in os.environ}
        env.update(HOME=str(home), PATH='/usr/bin:/bin:/usr/sbin:/sbin', SHELL='/bin/zsh',
                   XDG_RUNTIME_DIR=str(runtime_directory),
                   XDG_CONFIG_HOME=str(state / 'config'), XDG_DATA_HOME=str(state / 'data'),
                   TELAR_HISTORY=str(state / 'history.db'))

        def cli(*parts):
            command = [str(runtime), *map(str, parts), '--socket', str(socket)]
            result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=8)
            record['commands'].append(dict(command=command, actual_exit=result.returncode,
                                           stdout=result.stdout, stderr=result.stderr))
            result.check_returncode()
            return json.loads(result.stdout) if '--json' in parts else result.stdout

        def clients():
            return [client for client in cli('client', 'list', '--json')
                    if client['identity'] != 0 and client['attachments'] > 0]

        def require_clean_qml():
            warnings = []
            for name in ('direct.log', 'finder.log', 'finder-error.log', 'concurrent.log'):
                path = evidence / name
                if path.exists():
                    warnings.extend(dict(file=name, text=line) for line in path.read_text().splitlines()
                                    if 'qrc:/' in line or 'QML ' in line or 'QQmlApplicationEngine failed' in line)
            record['qml_warnings'] = warnings
            assert not warnings, warnings

        try:
            with (evidence / 'runtime.log').open('w') as log:
                server = subprocess.Popen([str(runtime), 'server', '--no-config', '--fresh', '--socket', str(socket)],
                                          env=env, stdout=log, stderr=subprocess.STDOUT)
            wait_for(socket.is_socket, bool)
            common = ['--fresh', '--cwd', str(state)]
            if not args.discover_runtime:
                common.extend(['--socket', str(socket), '--config', str(configuration)])
            with (evidence / 'direct.log').open('w') as log:
                direct = subprocess.Popen([str(launcher), *common, '--smoke-ms', '5000',
                                           '--screenshot', str(evidence / 'direct.png'),
                                           '/bin/sh', '-c', 'printf "C++ Unicode: á λ 漢字 ✓\\n"; sleep 60'],
                                          env=env, stdout=log, stderr=subprocess.STDOUT)
            first = wait_for(clients, bool)[0]
            initial_panes = wait_for(lambda: cli('pane', 'list', '--json'), bool)
            wait_for(lambda: cli('pane', 'read', initial_panes[-1]['pane_id']), lambda value: 'á λ 漢字 ✓' in value)
            if args.components:
                wait_for(lambda: component_marker.read_text() if component_marker.exists() else '', lambda value: value == 'ready')
                record['bundled_bar_command_ready'] = True
            record['direct_gui_exit'] = direct.wait(timeout=15)
            assert record['direct_gui_exit'] == 0
            assert (evidence / 'direct.png').is_file()
            assert 'connected=1' in (evidence / 'direct.log').read_text()
            require_clean_qml()
            wait_for(clients, lambda value: not value)

            command = ['/usr/bin/open', '-n', '-W', '-g', '-a', str(bundle),
                       '--stdout', str(evidence / 'finder.log'), '--stderr', str(evidence / 'finder-error.log')]
            for key, value in env.items():
                command.extend(['--env', key + '=' + value])
            finder_duration = 45000 if args.windows else 30000
            command.extend(['--args', *common, '--smoke-ms', str(finder_duration),
                            '--screenshot', str(evidence / 'finder.png'), '/bin/sh', '-c', 'sleep 60'])
            record['finder_command'] = command
            finder = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            client = wait_for(clients, bool)[0]
            client_id = str(client['id'])
            record['clients'] = dict(direct=first, finder=client)
            panes = wait_for(lambda: cli('pane', 'list', '--json'), bool)
            focused = next((pane for pane in panes if pane['pane_id'] == client['last_input_pane']), None)
            if focused is None:
                assert len(panes) == 1, 'ambiguous private starting pane'
                focused = panes[0]
            pane_id = str(focused['pane_id'])
            workspace = str(focused['workspace_id'])
            tab_id = str(focused['tab_id'])
            cli('tab', 'rename', tab_id, 'Diario á λ', '--workspace', workspace, '--json')
            renamed = cli('tab', 'list', '--workspace', workspace, '--json')
            assert any(tab.get('label') == 'Diario á λ' for tab in renamed)
            cli('pane', 'split', pane_id, 'horizontal', '--client', client_id, '--json')
            wait_for(lambda: cli('pane', 'list', '--json'), lambda value: len(value) > len(panes))
            cli('pane', 'resize', pane_id, 'right', '--client', client_id, '--json')
            assert cli('pane', 'fullscreen', pane_id, '--client', client_id, '--json')['value'] == 1
            assert cli('pane', 'fullscreen', pane_id, '--client', client_id, '--json')['value'] == 0
            cli('sidebar', 'hide', '--client', client_id, '--json')
            cli('sidebar', 'show', '--client', client_id, '--json')
            if args.plugins:
                cli('plugin', 'list', '--client', client_id, '--json')
                cli('plugin', 'get', 'bundle-smoke', '--client', client_id, '--json')
                for target, expected in [('bundle-smoke', False), ('example', True)]:
                    cli('plugin', 'run', target, 'toggle', '--client', client_id, '--json')
                    wait_for(lambda: cli('config', 'show', '--client', client_id, '--section', 'client', '--json'),
                             lambda value: value['sidebar_visible'] is expected)
            before_tabs = cli('tab', 'list', '--workspace', workspace, '--json')
            cli('tab', 'create', '--client', client_id, '--label', 'Second daily tab', '--json')
            wait_for(lambda: cli('tab', 'list', '--workspace', workspace, '--json'), lambda value: len(value) > len(before_tabs))
            cli('tab', 'move', tab_id, 'next', '--workspace', workspace, '--json')
            cli('config', 'show', '--client', client_id, '--section', 'input', '--json')
            adopted = cli('config', 'show', '--client', client_id, '--section', 'client', '--json')
            assert adopted['source'] == str(configuration) and adopted['generation'] > 0, adopted
            if args.windows:
                with (evidence / 'concurrent.log').open('w') as log:
                    concurrent = subprocess.Popen([str(launcher), *common, '--smoke-ms', '8000',
                                                   '--screenshot', str(evidence / 'concurrent.png'), '/bin/sh', '-c', 'sleep 60'],
                                                  env=env, stdout=log, stderr=subprocess.STDOUT)
                simultaneous = wait_for(clients, lambda value: len(value) == 2)
                assert len({entry['identity'] for entry in simultaneous}) == 2, simultaneous
                record['simultaneous_clients'] = simultaneous
                for entry in simultaneous:
                    current = cli('config', 'show', '--client', str(entry['id']), '--section', 'client', '--json')
                    assert current['source'] == str(configuration) and current['generation'] > 0, current
                observed = subprocess.check_output(['/bin/ps', '-p', str(concurrent.pid), '-o', 'comm='], text=True).strip()
                assert Path(observed) == bundle / 'Contents/MacOS/telar-gui', observed
                command = [str(runtime), 'exec', 'start', '--socket', str(socket), '--cwd', str(state),
                           '--no-stdin', '--timeout', '3', '--', '/usr/bin/printf', 'runtime-while-gui-paused']
                suspension = dict(scope='SIGSTOP/SIGCONT only for the exact owned relocated GUI child; runtime remains responsive. Physical system sleep is outside this smoke.',
                                  pid=concurrent.pid, observed_executable=observed)
                record['client_suspension'] = suspension
                os.kill(concurrent.pid, signal.SIGSTOP)
                try:
                    result = subprocess.run(command, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
                    record['commands'].append(dict(command=command, actual_exit=result.returncode,
                                                   stdout=result.stdout, stderr=result.stderr))
                    result.check_returncode()
                    assert result.stdout == 'runtime-while-gui-paused', result.stdout
                    suspension['runtime_responded'] = True
                    time.sleep(.5)
                finally:
                    os.kill(concurrent.pid, signal.SIGCONT)
                    suspension['resumed'] = True
                record['concurrent_gui_exit'] = concurrent.wait(timeout=15)
                assert record['concurrent_gui_exit'] == 0
                assert 'connected=1' in (evidence / 'concurrent.log').read_text()
                assert (evidence / 'concurrent.png').is_file()
                wait_for(clients, lambda value: len(value) == 1 and value[0]['id'] == client['id'])
            cli('config', 'reload', '--client', client_id, '--json')
            cli('client', 'open', 'history', '--client', client_id, '--json')
            stdout, stderr = finder.communicate(timeout=finder_duration / 1000 + 10)
            record['launchservices_exit'] = finder.returncode
            record['launchservices_stdout'] = stdout
            record['launchservices_stderr'] = stderr
            assert finder.returncode == 0
            text = (evidence / 'finder.log').read_text()
            assert 'connected=1' in text and 'error=\n' in text, text
            assert (evidence / 'finder.png').is_file()
            require_clean_qml()
            record['finder_gui_exit'] = 'unknown: open does not expose application exit status; healthy final marker required'
            record['configuration_unchanged'] = configuration.read_bytes() == initial_configuration
            assert record['configuration_unchanged']
            record['passed'] = True
        finally:
            for name, process in [('launchservices', finder), ('concurrent', concurrent), ('direct', direct), ('private-runtime', server)]:
                if process is not None:
                    if name == 'launchservices' and process.poll() is None:
                        # Let the bounded GUI close itself before removing its runtime/state.
                        try:
                            process.wait(timeout=finder_duration / 1000 + 10)
                        except subprocess.TimeoutExpired:
                            raise RuntimeError('preview did not close; preserve its state for inspection')
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                    record['processes'].append(dict(name=name, pid=process.pid, actual_exit=process.returncode))
            (evidence / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    record['private_state_removed'] = not state.exists()
    (evidence / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({key: record[key] for key in ('passed', 'private_state_removed')}))


if __name__ == '__main__':
    main()
