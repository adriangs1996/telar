import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading
import time


def execute(binary, payload, source, png, mode):
    reading, writing = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
    os.set_blocking(writing, True)
    environment = dict(os.environ, PIPE_SOURCE_LIMIT=str(source), PIPE_PNG_LIMIT=str(png))
    started = time.monotonic()
    process = subprocess.Popen([str(binary), str(source), str(png)], stdin=reading, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
    os.close(reading)
    stop = threading.Event()
    errors = []

    def provide():
        try:
            if mode == 'partial-stall':
                if stop.wait(3):
                    return
            position = 0
            while position < len(payload) and not stop.is_set():
                position += os.write(writing, payload[position:position + 4096])
            if mode in ('stall', 'partial-stall'):
                stop.wait(8)
        except BrokenPipeError:
            pass
        except Exception as failure:
            errors.append(repr(failure))
        finally:
            os.close(writing)

    provider = threading.Thread(target=provide)
    provider.start()
    try:
        output, diagnostics = process.communicate(timeout=8)
    except BaseException:
        process.kill()
        process.communicate()
        raise
    finally:
        stop.set()
        provider.join(timeout=2)
    elapsed = time.monotonic() - started
    assert not provider.is_alive() and not errors, errors
    assert process.returncode == 0, (process.returncode, diagnostics)
    assert b'ERROR: AddressSanitizer' not in diagnostics and b'runtime error:' not in diagnostics, diagnostics
    return output, dict(binary=str(binary), exit_code=process.returncode, elapsed_seconds=elapsed, output_bytes=len(output), output_sha256=hashlib.sha256(output).hexdigest(), stderr=diagnostics.decode(errors='replace'))


def main():
    parser = argparse.ArgumentParser(description='Compare bounded pipe outcomes and binary payloads against unchanged Zig source')
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    directory = options.output.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    binaries = [options.reference.resolve(), options.candidate.resolve()]
    receipt = dict(binaries={str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in binaries}, cases=[])
    receipt['sanitizers'] = {name: os.environ.get(name) for name in ('ASAN_OPTIONS', 'UBSAN_OPTIONS', 'LSAN_OPTIONS')}
    receipt['dbus_session_present'] = bool(os.environ.get('DBUS_SESSION_BUS_ADDRESS'))
    payload = bytes(range(256)) * 257
    cases = [('empty', b'', 0, 0, 'eof'), ('binary', payload, len(payload), len(payload), 'eof'), ('source', payload, 17000, len(payload), 'eof'), ('png', payload, len(payload), 17000, 'eof'), ('precedence', payload, 17000, 17000, 'eof'), ('zero-source', b'x', 0, 10, 'eof'), ('zero-png', b'x', 10, 0, 'eof'), ('stall', b'', 100, 100, 'stall'), ('partial-stall', b'x', 100, 100, 'partial-stall')]
    expected = {'empty': b'NoImageOnClipboard\n', 'binary': b'ok\n' + payload, 'source': b'ClipboardSourceTooLarge\n', 'png': b'ClipboardPngTooLarge\n', 'precedence': b'ClipboardSourceTooLarge\n', 'zero-source': b'ClipboardSourceTooLarge\n', 'zero-png': b'ClipboardPngTooLarge\n', 'stall': b'ClipboardReadFailed\n', 'partial-stall': b'ClipboardReadFailed\n'}
    for name, data, source, png, mode in cases:
        records = []
        for index, binary in enumerate(binaries):
            observed, record = execute(binary, data, source, png, mode)
            (directory / (name + '-' + str(index) + '.bin')).write_bytes(observed)
            records.append(record)
            receipt['cases'].append(dict(name=name, implementation=index, record=record))
            (directory / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')
            assert observed == expected[name], (name, observed[:100])
            if 'stall' in mode:
                assert 4.9 <= record['elapsed_seconds'] < 7, record
        assert records[0]['output_sha256'] == records[1]['output_sha256'], name
    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == receipt['binaries'][str(path)] for path in binaries), 'A probe binary changed during qualification'
    receipt['passed'] = True
    (directory / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('Passed9 original-source pipe cases; binary data and failure precedence exact; total deadline retained')


if __name__ == '__main__':
    main()
