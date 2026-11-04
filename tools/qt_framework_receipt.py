"""Validate post-measurement Darwin image receipts against frozen Qt frameworks."""

import hashlib
from pathlib import Path


def verify_loaded_qt_images(result, expected):
    images = result.get('loaded_images')
    if not isinstance(images, list) or not images:
        raise ValueError('Missing loaded-image receipt')
    observed = {}
    for name in images:
        if not isinstance(name, str) or not Path(name).is_absolute():
            raise ValueError('Invalid loaded-image path')
        path = Path(name)
        frameworks = [part.removesuffix('.framework') for part in path.parts if part.endswith('.framework')]
        if not frameworks or not frameworks[-1].startswith('Qt'):
            continue
        module = frameworks[-1]
        if module not in expected or module in observed or path.name != module:
            raise ValueError(f'Unexpected or duplicate Qt framework: {name}')
        specification = expected[module]
        actual = path.resolve(strict=True)
        if actual != Path(specification['path']).resolve(strict=True):
            raise ValueError(f'Wrong loaded {module}: {actual}')
        digest = hashlib.sha256(actual.read_bytes()).hexdigest()
        if digest != specification['sha256']:
            raise ValueError(f'Loaded {module} differs from its frozen bytes')
        observed[module] = dict(loaded_path=name, resolved_path=str(actual), sha256=digest)
    if not {'QtCore', 'QtGui', 'QtQuick'} <= observed.keys():
        raise ValueError('Missing required Qt GUI framework')
    return observed
