"""Owned history wire census with optional delayed replies; never a timing oracle."""

import asyncio
import hashlib
import math
import time

from history_capture_proxy import (HistoryCaptureProxy, read_frame, request_identity,
                                   query_length, query_history_tag, history_results_tag,
                                   request_failed_tag)


class HistoryQueryTrace(HistoryCaptureProxy):
    maximum_events = 4096
    maximum_pending = 128

    def __init__(self, target, directory, reply_delays=None):
        super().__init__(target, directory, 'trace', '')
        self.reply_delays = dict(reply_delays or {})
        if any(not isinstance(query, str) or not math.isfinite(delay) or not 0 <= delay <= 1
               for query, delay in self.reply_delays.items()):
            raise ValueError('Reply delays must map query text to 0..1 seconds')
        self.next_connection = 0
        self.peak_pending = 0

    def record(self):
        return dict(mode=self.mode, target=str(self.target), endpoint=str(self.endpoint),
                    queries=list(self.queries), responses=list(self.responses), errors=list(self.errors),
                    peak_pending=self.peak_pending, reply_delays=self.reply_delays,
                    scope='Diagnostic relay. Every frame is forwarded byte-exactly. Selected history replies may be delayed or reordered; all instrumented timing is ineligible.')

    async def connect(self, client_reader, client_writer):
        connection = asyncio.current_task()
        self.connections.add(connection)
        self.next_connection += 1
        identity = self.next_connection
        runtime_writer = None
        tasks = []
        delayed = set()
        pending = {}
        try:
            runtime_reader, runtime_writer = await asyncio.open_unix_connection(self.target)
            tasks = [asyncio.create_task(self.trace_requests(client_reader, runtime_writer, identity, pending)),
                     asyncio.create_task(self.trace_replies(runtime_reader, client_writer, identity, pending, delayed))]
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        except Exception as error:
            self.errors.append(repr(error))
        finally:
            active = [*tasks, *delayed]
            for task in active:
                task.cancel()
            await asyncio.gather(*active, return_exceptions=True)
            for writer in (client_writer, runtime_writer):
                if writer is not None:
                    writer.close()
                    try:
                        await writer.wait_closed()
                    except ConnectionError:
                        pass
            self.connections.discard(connection)

    async def trace_requests(self, reader, writer, connection, pending):
        while True:
            prefix, payload = await read_frame(reader)
            if payload[0] == query_history_tag:
                if len(payload) < 1 + request_identity.size + query_length.size:
                    raise ValueError('Truncated history query')
                identity, = request_identity.unpack_from(payload, 1)
                size_position = 1 + request_identity.size
                size, = query_length.unpack_from(payload, size_position)
                position = size_position + query_length.size
                if position + size > len(payload) or identity in pending:
                    raise ValueError('Truncated or duplicate pending history query')
                if len(self.queries) >= self.maximum_events or len(pending) >= self.maximum_pending:
                    raise ValueError('History diagnostic census capacity exceeded')
                row = dict(connection=connection, identity=identity,
                           query=payload[position:position + size].decode('utf-8'),
                           received_ns=time.monotonic_ns(), sha256=hashlib.sha256(prefix + payload).hexdigest())
                self.queries.append(row)
                pending[identity] = row
                self.peak_pending = max(self.peak_pending, len(pending))
            writer.write(prefix + payload)
            await writer.drain()

    async def trace_replies(self, reader, writer, connection, pending, delayed):
        async def forward(frame, row, delay):
            try:
                if delay:
                    await asyncio.sleep(delay)
                writer.write(frame)
                await writer.drain()
                row['forwarded_ns'] = time.monotonic_ns()
                pending.pop(row['identity'], None)
            except (ConnectionError, OSError) as error:
                self.errors.append(repr(error))

        while True:
            prefix, payload = await read_frame(reader)
            if payload[0] in (history_results_tag, request_failed_tag):
                if len(payload) < 1 + request_identity.size:
                    raise ValueError('Truncated history response')
                identity, = request_identity.unpack_from(payload, 1)
                request = pending.get(identity)
                if request is not None:
                    if len(self.responses) >= self.maximum_events:
                        raise ValueError('History diagnostic census capacity exceeded')
                    delay = self.reply_delays.get(request['query'], 0)
                    row = dict(connection=connection, identity=identity, tag=payload[0],
                               received_ns=time.monotonic_ns(), delay_seconds=delay,
                               sha256=hashlib.sha256(prefix + payload).hexdigest())
                    self.responses.append(row)
                    if not delay:
                        await forward(prefix + payload, row, delay)
                        continue
                    task = asyncio.create_task(forward(prefix + payload, row, delay))
                    delayed.add(task)
                    task.add_done_callback(delayed.discard)
                    continue
            writer.write(prefix + payload)
            await writer.drain()
