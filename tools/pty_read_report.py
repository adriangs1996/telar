"""Decode a terminated Darwin PTY read diagnostic; never accept timing from it."""

from pathlib import Path
import struct

HEADER = struct.Struct('<8Q')
RECORD = struct.Struct('<5Qq4Q')
MAGIC = 0x31524452595450
RECORD_CAPACITY = 16384
BYTE_CAPACITY = 4 * 1024 * 1024


def read_trace(path, pid):
    if type(pid) is not int or not 0 < pid <= 2**31 - 1:
        raise ValueError('Invalid PTY trace process identity')
    data = Path(path).read_bytes()
    expected_size = HEADER.size + RECORD_CAPACITY * RECORD.size + BYTE_CAPACITY
    if len(data) != expected_size:
        raise ValueError('Wrong PTY trace size')
    magic, version, capacity, byte_capacity, used, byte_used, overflow, complete = HEADER.unpack_from(data)
    if (magic, version, capacity, byte_capacity) != (MAGIC, 1, RECORD_CAPACITY, BYTE_CAPACITY):
        raise ValueError('Wrong PTY trace format')
    if complete != 1 or overflow or not 0 < used <= capacity or byte_used > byte_capacity:
        raise ValueError('Empty, incomplete or overflowing PTY trace')
    records, offset = [], 0
    payload = HEADER.size + capacity * RECORD.size
    for index in range(used):
        start, end, owner, descriptor, requested, result, error, position, length, ready = RECORD.unpack_from(
            data, HEADER.size + index * RECORD.size)
        if (ready != 1 or owner != pid or not 0 < start <= end or result < -1
                or descriptor > 2**31 - 1 or error > 2**31 - 1 or (result == -1 and not error)
                or length != max(0, result) or result > requested or position != offset
                or offset + length > byte_used):
            raise ValueError('Invalid PTY read record')
        records.append(dict(begin_ns=start, end_ns=end, pid=owner, descriptor=descriptor,
                            requested=requested, result=result, error=error,
                            data=data[payload + offset:payload + offset + length]))
        offset += length
    if offset != byte_used:
        raise ValueError('PTY byte partition mismatch')
    return records
