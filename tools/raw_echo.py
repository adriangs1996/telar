#!/usr/bin/env python3
"""Echoes a raw-mode tty's input itself, DEL as an erase. The graphics gate
uses it instead of the line discipline's echo, which on BSD retypes the line
when another writer's output lands between a key and its erase."""
import os

ERASE = b'\x7f'

while True:
    data = os.read(0, 64)
    if not data:
        break
    os.write(1, data.replace(ERASE, b'\b \b'))
