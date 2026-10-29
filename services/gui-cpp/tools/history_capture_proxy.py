import asyncio
import json
from pathlib import Path
import struct
import tempfile
import threading


frame_prefix = struct.Struct('<I')
request_identity = struct.Struct('<Q')
query_length = struct.Struct('<H')
maximum_payload_bytes = 4 * 1024 * 1024
query_history_tag = 0x0B
history_results_tag = 0x87
request_failed_tag = 0x84
fixture_failure_code = 1
fixture_failure_message = b'History fixture failure'


async def read_frame(reader):
    prefix = await reader.readexactly(frame_prefix.size)
    size, = frame_prefix.unpack(prefix)
    if not 0 < size <= maximum_payload_bytes:
        raise RuntimeError(f'Invalid fixture frame length: {size}')
    return prefix, await reader.readexactly(size)


class HistoryCaptureProxy:
    def __init__(self, target, directory, mode, query):
        self.target = Path(target)
        self.directory = Path(directory)
        self.temporary = tempfile.TemporaryDirectory(prefix='thp-', dir='/tmp')
        self.endpoint = Path(self.temporary.name) / 'socket'
        self.mode = mode
        self.query = query.encode()
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.loop = None
        self.finished = None
        self.connections = set()
        self.queries = []
        self.responses = []
        self.errors = []

    def start(self):
        self.thread.start()
        if not self.ready.wait(timeout=10) or self.errors:
            raise RuntimeError(f'History proxy failed to start: {self.errors}')
        return self.endpoint

    def record(self):
        return dict(mode=self.mode, target=str(self.target), endpoint=str(self.endpoint),
                    queries=list(self.queries), responses=list(self.responses), errors=list(self.errors),
                    scope='Isolated validation proxy. Unrelated frames pass through unchanged. Selected history queries are withheld or receive a synthetic RequestFailed frame; production code is unchanged.')

    def stop(self):
        if self.loop is not None and self.finished is not None and self.thread.is_alive():
            self.loop.call_soon_threadsafe(self.finished.set)
            self.thread.join(timeout=10)
        if self.thread.is_alive():
            raise RuntimeError('History proxy did not stop')
        self.endpoint.unlink(missing_ok=True)
        self.temporary.cleanup()
        (self.directory / 'runtime-proxy.json').write_text(json.dumps(self.record(), indent=2) + '\n')

    def serve(self):
        try:
            asyncio.run(self.run())
        except Exception as error:
            self.errors.append(repr(error))
            self.ready.set()

    async def run(self):
        self.loop = asyncio.get_running_loop()
        self.finished = asyncio.Event()
        server = await asyncio.start_unix_server(self.connect, path=self.endpoint)
        self.endpoint.chmod(0o600)
        self.ready.set()
        async with server:
            await self.finished.wait()
        active = list(self.connections)
        for task in active:
            task.cancel()
        await asyncio.gather(*active, return_exceptions=True)

    async def connect(self, client_reader, client_writer):
        connection = asyncio.current_task()
        self.connections.add(connection)
        runtime_writer = None
        tasks = []
        try:
            runtime_reader, runtime_writer = await asyncio.open_unix_connection(self.target)
            tasks = [asyncio.create_task(self.requests(client_reader, runtime_writer, client_writer)),
                     asyncio.create_task(self.replies(runtime_reader, client_writer))]
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        except Exception as error:
            self.errors.append(repr(error))
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            for writer in [client_writer, runtime_writer]:
                if writer is not None:
                    writer.close()
                    try:
                        await writer.wait_closed()
                    except ConnectionError:
                        pass
            self.connections.discard(connection)

    async def requests(self, reader, runtime, client):
        while True:
            prefix, payload = await read_frame(reader)
            intercepted = False
            if payload[0] == query_history_tag:
                identity, = request_identity.unpack_from(payload, 1)
                size_position = 1 + request_identity.size
                size, = query_length.unpack_from(payload, size_position)
                query_position = size_position + query_length.size
                query = payload[query_position:query_position + size]
                intercepted = self.mode == 'initial-loading' or query == self.query
                self.queries.append(dict(identity=identity, query=query.decode(errors='replace'), intercepted=intercepted))
                if intercepted and self.mode == 'error':
                    failure = bytes([request_failed_tag]) + request_identity.pack(identity) + struct.pack('<H', fixture_failure_code) + fixture_failure_message
                    client.write(frame_prefix.pack(len(failure)) + failure)
                    await client.drain()
            if not intercepted:
                runtime.write(prefix + payload)
                await runtime.drain()

    async def replies(self, reader, client):
        while True:
            prefix, payload = await read_frame(reader)
            if payload[0] == history_results_tag:
                identity, = request_identity.unpack_from(payload, 1)
                self.responses.append(identity)
            client.write(prefix + payload)
            await client.drain()
