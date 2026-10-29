#!/usr/bin/env python3
"""Exercise real application handlers without desktop access or a running runtime."""
import ctypes
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class ForeignResponse(AssertionError):
    def __init__(self, reply, calls):
        super().__init__('A control input reached a foreign response handler')
        self.reply = reply
        self.calls = calls

class Probe:
    def __init__(self, library, geometry=(80, 24, 9, 18)):
        self.lib = ctypes.CDLL(str(library))
        self.lib.query_probe_new.argtypes = [ctypes.c_uint16] * 4
        self.lib.query_probe_new.restype = ctypes.c_void_p
        self.lib.query_probe_free.argtypes = [ctypes.c_void_p]
        self.lib.query_probe_feed.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
        self.lib.query_probe_feed.restype = ctypes.c_bool
        self.lib.query_probe_drain.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
        self.lib.query_probe_drain.restype = ctypes.c_size_t
        self.foreign_calls = getattr(self.lib, 'query_probe_foreign_calls', None)
        if self.foreign_calls:
            self.foreign_calls.argtypes = [ctypes.c_void_p]
            self.foreign_calls.restype = ctypes.c_uint64
        self.ptr = self.lib.query_probe_new(*geometry)
        if not self.ptr:
            raise RuntimeError('Probe construction failed')

    def close(self):
        if self.ptr:
            self.lib.query_probe_free(self.ptr)
            self.ptr = None

    def feed(self, data):
        if not self.lib.query_probe_feed(self.ptr, data, len(data)):
            raise RuntimeError('Probe rejected input')

    def policy(self, flags=0, answerback=b''):
        self._answerback = answerback
        self.lib.query_probe_policy.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t]
        self.lib.query_probe_policy.restype = ctypes.c_bool
        assert self.lib.query_probe_policy(self.ptr, flags, answerback, len(answerback))

    def drain(self):
        result = bytearray()
        buffer = ctypes.create_string_buffer(4 * 1024 * 1024)
        while True:
            size = self.lib.query_probe_drain(self.ptr, buffer, len(buffer))
            if not size:
                return bytes(result)
            result += buffer.raw[:size]

    def run(self, data, split=None):
        if split is None:
            self.feed(data)
        else:
            self.feed(data[:split])
            self.feed(data[split:])
        result = self.drain()
        if self.foreign_calls and self.foreign_calls(self.ptr):
            raise ForeignResponse(result, self.foreign_calls(self.ptr))
        return result

GHOSTTY = ROOT / 'dependencies/control-baselines/ghostty-application/libghostty-control-oracle-threaded.dylib'
NATIVE = ROOT / 'out-control-native-df/libcontrol-query-probe.dylib'
