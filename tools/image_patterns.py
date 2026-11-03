"""Deterministic payloads for image latency and original-renderer pixel oracles."""

PATTERNS = ('opaque', 'alpha-edge', 'alpha-gradient')
COLORS = ((230, 20, 60, 255), (20, 220, 200, 255), (180, 180, 180, 255))
ALPHA_SIZE = (16, 16)
ALPHA_CELLS = (8, 4)
BORDER_COLOR = (90, 90, 90, 255)
MARKER_RANGE = range(6, 10)
OPAQUE_EDGE = (120, 20, 20, 255)
TRANSPARENT_EDGE = (20, 20, 120, 0)


def placement(size, pattern):
    if pattern not in PATTERNS:
        raise ValueError('unknown image pattern')
    if pattern == 'opaque':
        return None
    if tuple(size) != ALPHA_SIZE:
        raise ValueError('alpha image patterns require a 16x16 source')
    return ALPHA_CELLS


def frames(size, pattern):
    placement(size, pattern)
    if pattern == 'opaque':
        return tuple(bytes(color) * (size[0] * size[1]) for color in COLORS)
    width, height = size
    result = []
    for marker in COLORS:
        output = bytearray()
        for y in range(height):
            for x in range(width):
                if x in (0, width - 1) or y in (0, height - 1):
                    color = BORDER_COLOR
                elif x in MARKER_RANGE and y in MARKER_RANGE:
                    color = marker
                elif pattern == 'alpha-edge':
                    color = OPAQUE_EDGE if x < width // 2 else TRANSPARENT_EDGE
                elif y < height // 2:
                    color = (20 + 7 * x, 20 + 7 * y, 120 - 6 * x, (17 * x + 29 * y) % 256)
                else:
                    color = (120, 25, 95, 85 if (x + y) % 2 else 170)
                output.extend(color)
        result.append(bytes(output))
    return tuple(result)
