#!/usr/bin/env python3
import hashlib
import json
import struct

import check_plugin_data as data


def package(root, name, identity=None, capabilities=None):
    directory = root / name
    directory.mkdir()
    manifest = data.manifest()
    manifest['id'] = identity or name
    manifest['capabilities'] = capabilities if capabilities is not None else ['proxy.tap', 'notifications']
    (directory / 'plugin.json').write_bytes(data.encoded(manifest))
    (directory / 'main.lua').write_text('return {on_exchange=function() return nil end}')
    return directory


def grant(directory, capabilities=None):
    digest = hashlib.sha256(b'telar-plugin-package-v1\0')
    for path in sorted(directory.iterdir()):
        name = path.name.encode()
        contents = path.read_bytes()
        digest.update(struct.pack('<Q', len(name)) + name + struct.pack('<Q', len(contents)) + contents)
    manifest = json.loads((directory / 'plugin.json').read_text())
    return {'plugin': manifest['id'], 'digest': digest.hexdigest(),
            'capabilities': capabilities if capabilities is not None else ['proxy.tap', 'notifications']}
