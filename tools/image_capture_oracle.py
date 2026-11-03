"""Compare the opaque-bordered image fixture in qualified native captures.

This is a static pixel oracle, not a latency or cadence acceptance tool. The
border determines the footprint independently of the color-derived marker center.
It does not replace or relax the headline runner's geometry checks.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path

from PIL import Image, ImageChops

from image_patterns import BORDER_COLOR
from terminal_bench_report import latency_samples, validate_telar_display_sync


BORDER_RGBA = BORDER_COLOR
SEARCH_RADIUS = 400
MINIMUM_BORDER_PIXELS = 64
GEOMETRY_FIELDS = ('viewport', 'requested_viewport', 'backing_scale', 'pty_cells',
                   'image_size', 'scene_pixels', 'native_view_pixels')
SOURCE_FIELDS = ('width', 'height', 'format', 'bytes_per_image', 'payload_sha256', 'transport')


def source_identity(result):
    fixtures = [fixture for fixture in result.get('fixtures', []) if fixture.get('role') == 'primary']
    if len(fixtures) != 1 or fixtures[0].get('error'):
        raise ValueError('one successful primary image fixture is required')
    source = fixtures[0].get('image', {})
    if any(source.get(key) is None for key in SOURCE_FIELDS):
        raise ValueError('incomplete image source identity')
    if (source['format'] != 'RGBA8888' or source['transport'] != 'kitty-shared-memory'
            or [source['width'], source['height']] != result.get('image_size')
            or source['width'] <= 0 or source['height'] <= 0
            or source['bytes_per_image'] != source['width'] * source['height'] * 4
            or not isinstance(source['payload_sha256'], list) or len(source['payload_sha256']) != 3):
        raise ValueError('unexpected image fixture format, extent or payloads')
    for digest in source['payload_sha256']:
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise ValueError('invalid source payload digest')
    return {key: source[key] for key in SOURCE_FIELDS}


def load_capture(path):
    result = json.loads(path.read_text())
    if (result.get('endpoint') != 'presented' or result.get('failed') != 0
            or result.get('error') or result.get('capture_witness_verified') is not True):
        raise ValueError('a successful native presentation and capture witness are required')
    validate_telar_display_sync(result)
    latency_samples(result)
    for field in ('window_key_start', 'window_key_end', 'app_active_start', 'app_active_end'):
        values = result.get(field)
        if not isinstance(values, list) or not values or any(value is not True for value in values):
            raise ValueError('native focus was not retained')
    if any(result.get(key) is None for key in GEOMETRY_FIELDS):
        raise ValueError('incomplete native geometry')
    source = source_identity(result)
    capture = result['capture']
    data = Path(capture['path']).read_bytes()
    if hashlib.sha256(data).hexdigest() != capture['sha256']:
        raise ValueError('capture file does not match its recorded digest')
    with Image.open(io.BytesIO(data)) as original:
        image = original.convert('RGBA')
    if list(image.size) != result['viewport']:
        raise ValueError('capture dimensions do not match the native viewport')
    return result, source, image


def image_footprint(image, marker):
    marker_x, marker_y = marker
    region = (max(0, marker_x - SEARCH_RADIUS), max(0, marker_y - SEARCH_RADIUS),
              min(image.width, marker_x + SEARCH_RADIUS), min(image.height, marker_y + SEARCH_RADIUS))
    pixels = image.load()
    border = {(x, y) for y in range(region[1], region[3]) for x in range(region[0], region[2])
              if pixels[x, y] == BORDER_RGBA}
    matches = []
    while border:
        start = border.pop()
        pending, component = [start], [start]
        while pending:
            x, y = pending.pop()
            for point in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if point in border:
                    border.remove(point)
                    pending.append(point)
                    component.append(point)
        if len(component) < MINIMUM_BORDER_PIXELS:
            continue
        bounds = (min(x for x, _ in component), min(y for _, y in component),
                  max(x for x, _ in component) + 1, max(y for _, y in component) + 1)
        if bounds[0] < marker_x < bounds[2] and bounds[1] < marker_y < bounds[3]:
            matches.append((bounds, len(component)))
    if len(matches) != 1:
        raise ValueError('capture must contain one connected opaque border around its marker')
    return matches[0]


def compare(reference_path, candidate_path):
    reference, source, left = load_capture(reference_path)
    candidate, other_source, right = load_capture(candidate_path)
    if source != other_source:
        raise ValueError('source image payloads or dimensions differ')
    for field in GEOMETRY_FIELDS:
        if reference[field] != candidate[field]:
            raise ValueError(f'native geometry differs: {field}')
    captures, crops = {}, []
    for label, result, image in (('reference', reference, left), ('candidate', candidate, right)):
        bounds, border_pixels = image_footprint(image, result['marker'])
        crop = image.crop(bounds)
        crops.append(crop)
        captures[label] = dict(bounds=list(bounds), size=list(crop.size), border_pixels=border_pixels,
                               marker=result['marker'], rgba_sha256=hashlib.sha256(crop.tobytes()).hexdigest(),
                               capture_sha256=result['capture']['sha256'])
    if captures['reference']['bounds'] != captures['candidate']['bounds']:
        raise ValueError('opaque image footprints differ')
    difference = ImageChops.difference(*crops).tobytes()
    changed = sum(any(difference[offset:offset + 4]) for offset in range(0, len(difference), 4))
    return dict(scope='Static native bordered image; not latency or cadence acceptance',
                reference=str(reference_path.resolve()), candidate=str(candidate_path.resolve()),
                source=source, geometry={key: reference[key] for key in GEOMETRY_FIELDS}, captures=captures,
                exact=changed == 0, different_pixels=changed, maximum_channel_difference=max(difference))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = compare(args.reference, args.candidate)
    text = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    print(text, end='')
    return 0 if report['exact'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
