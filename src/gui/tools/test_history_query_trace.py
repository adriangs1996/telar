import asyncio
import hashlib
from pathlib import Path
import struct
import tempfile
import unittest

from history_capture_proxy import frame_prefix, read_frame
from history_query_trace import HistoryQueryTrace


def framed(payload):
    return frame_prefix.pack(len(payload)) + payload


def query(identity, text):
    data = text.encode()
    return framed(b'\x0b' + struct.pack('<QH', identity, len(data)) + data + b'opaque query tail')


class HistoryQueryTraceTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='thqt-', dir='/tmp')
        self.directory = Path(self.temporary.name)
        self.received = []
        self.handlers = set()
        self.proxy = None
        self.client = None
        self.server = await asyncio.start_unix_server(self.runtime, path=self.directory / 'runtime')

    async def asyncTearDown(self):
        if self.proxy is not None:
            await asyncio.to_thread(self.proxy.stop)
        if self.client is not None:
            self.client.close()
            await self.client.wait_closed()
        self.server.close()
        await self.server.wait_closed()
        handlers = list(self.handlers)
        for handler in handlers:
            handler.cancel()
        await asyncio.gather(*handlers, return_exceptions=True)
        self.temporary.cleanup()

    async def runtime(self, reader, writer):
        task = asyncio.current_task()
        self.handlers.add(task)
        try:
            while True:
                prefix, payload = await read_frame(reader)
                self.received.append(prefix + payload)
                if payload[0] == 0x0b:
                    response = b'\x84' if b'failure' in payload else b'\x87'
                    payload = response + payload[1:9] + b'opaque result\x00\xff'
                writer.write(framed(payload))
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            writer.close()
            await writer.wait_closed()
            self.handlers.discard(task)

    async def connect(self, delays=None):
        self.proxy = HistoryQueryTrace(self.directory / 'runtime', self.directory, delays)
        endpoint = await asyncio.to_thread(self.proxy.start)
        reader, self.client = await asyncio.open_unix_connection(endpoint)
        return reader, self.client

    async def receive(self, reader):
        prefix, payload = await asyncio.wait_for(read_frame(reader), timeout=2)
        return prefix + payload

    async def test_delayed_old_reply_follows_new_reply_without_changing_bytes(self):
        reader, writer = await self.connect({'old': .1})
        requests = [query(1, 'old'), framed(b'\x7funtouched\x00\xff'), query(2, 'new')]
        writer.write(b''.join(requests))
        await writer.drain()
        replies = [await self.receive(reader) for _ in requests]
        expected = [requests[1], framed(b'\x87' + struct.pack('<Q', 2) + b'opaque result\x00\xff'),
                    framed(b'\x87' + struct.pack('<Q', 1) + b'opaque result\x00\xff')]
        self.assertEqual(replies, expected)
        self.assertEqual(self.received, requests)
        trace = self.proxy.record()
        self.assertEqual(trace['errors'], [])
        self.assertEqual(trace['peak_pending'], 2)
        self.assertEqual([row['query'] for row in trace['queries']], ['old', 'new'])
        self.assertEqual([row['sha256'] for row in trace['queries']], [hashlib.sha256(requests[i]).hexdigest() for i in (0, 2)])
        responses = sorted(trace['responses'], key=lambda row: row['forwarded_ns'])
        self.assertEqual([row['identity'] for row in responses], [2, 1])
        self.assertEqual([row['sha256'] for row in responses], [hashlib.sha256(reply).hexdigest() for reply in expected[1:]])
        self.assertTrue(all(row['forwarded_ns'] >= row['received_ns'] for row in responses))

    async def test_failures_retire_pending_requests_and_allow_identity_reuse(self):
        reader, writer = await self.connect()
        for text in ('failure', 'new'):
            writer.write(query(7, text))
            await writer.drain()
            response = await self.receive(reader)
            self.assertEqual(response[4], 0x84 if text == 'failure' else 0x87)
        self.assertEqual(self.proxy.record()['peak_pending'], 1)
        self.assertFalse(self.proxy.record()['errors'])

    async def test_pass_through_preserves_mixed_frame_order(self):
        reader, writer = await self.connect()
        requests = [query(1, 'one'), framed(b'\x7funrelated'), query(2, 'two')]
        writer.write(b''.join(requests))
        await writer.drain()
        replies = [await self.receive(reader) for _ in requests]
        self.assertEqual(replies, [framed(b'\x87' + struct.pack('<Q', 1) + b'opaque result\x00\xff'), requests[1],
                                   framed(b'\x87' + struct.pack('<Q', 2) + b'opaque result\x00\xff')])
        self.assertFalse(self.proxy.record()['errors'])

    async def test_malformed_query_is_reported_without_forwarding(self):
        reader, writer = await self.connect()
        writer.write(framed(b'\x0b\x01'))
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.read(), timeout=2), b'')
        self.assertFalse(self.received)
        self.assertIn('Truncated history query', str(self.proxy.record()['errors']))

    async def test_duplicate_pending_identity_is_reported(self):
        reader, writer = await self.connect({'old': 1})
        writer.write(query(9, 'old') + query(9, 'new'))
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.read(), timeout=2), b'')
        self.assertIn('duplicate pending history query', str(self.proxy.record()['errors']))

    async def test_census_capacity_is_bounded(self):
        reader, writer = await self.connect({'old': 1})
        self.proxy.maximum_pending = 2
        writer.write(query(1, 'old') + query(2, 'old') + query(3, 'old'))
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.read(), timeout=2), b'')
        self.assertEqual(len(self.proxy.record()['queries']), 2)
        self.assertIn('census capacity exceeded', str(self.proxy.record()['errors']))


if __name__ == '__main__':
    unittest.main()
