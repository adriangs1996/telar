import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

from check_tab_activity import prepare


colors = {1: 0x72B7AE, 2: 0xF27C7C, 4: 0xE8C56A}


def items():
    entries = []
    for side in [12, 14, 17.5]:
        for fraction in [.3, .65, 1]:
            for frame in range(8):
                entries.append(dict(kind='ring', size=[side, side], fraction=fraction, turns=frame/8, rgb=colors[1]))
    for ratio in [.5, 1, 1.25, 2]:
        for state in [1, 2, 4]:
            for percent in [0, 25, 100, None]:
                entries.append(dict(kind='capsule', size=[64, 40], ratio=ratio, state=state, percent=percent, rgb=colors[state]))
    for index, item in enumerate(entries):
        item['rect'] = [(index % 8)*80+8.25, (index//8)*48+3.5, *item.pop('size')]
    return entries


def encode(item):
    if item['kind'] == 'ring':
        rgb = item['rgb']
        color = [((rgb >> shift) & 255)/255 for shift in [16, 8, 0]] + [1]
        return struct.pack('<B10f', 1, *item['rect'], *color, item['fraction'], item['turns'])
    percent = 255 if item['percent'] is None else item['percent']
    return struct.pack('<B5fBBQ', 4, *item['rect'], item['ratio'], item['state'], percent, 0)


def decode(data, count):
    offset = 0
    shapes = []
    for _ in range(count):
        size = struct.unpack_from('<H', data, offset)[0]
        offset += 2
        for _ in range(size):
            values = struct.unpack_from('<14f', data, offset)
            offset += 56
            shapes.append(dict(rect=values[:4], radius=values[4], borderWidth=values[5], fill=values[6:10], border=values[10:14], opacity=1))
    if offset != len(data):
        raise RuntimeError('Unexpected original paint payload length')
    return shapes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    reference_command = prepare(root, work)
    entries = items()
    payload = b''.join(encode(item) for item in entries)
    result = subprocess.run([work/'original'], input=payload, capture_output=True, check=True)
    (work/'input.bin').write_bytes(payload)
    (work/'original.bin').write_bytes(result.stdout)
    document = dict(width=640, height=720, background=[16/255, 16/255, 16/255, 1], items=entries, shapes=decode(result.stdout, len(entries)))
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    request = output/'cases.json'
    request.write_text(json.dumps(document, indent=2)+'\n')
    helper = work/'metal-reference'
    command = ['clang++','-std=c++23','-fobjc-arc','-Wall','-Wextra','-Werror','-framework','Foundation','-framework','Metal','-framework','ImageIO','-framework','CoreGraphics',str(root/'services/gui-cpp/tools/rounded_rectangle_reference.mm'),'-o',str(helper)]
    subprocess.run(command, check=True)
    shader = root/'lib/window/shaders/quad.metal'
    subprocess.run([helper, shader, request, output/'atlas.png'], check=True)
    sources = [root/'src/gui/widgets'/name for name in ['ProgressRing.zig','PaneProgress.zig','ProgressMotions.zig']]
    sources += [shader, root/'services/gui-cpp/tools/rounded_rectangle_reference.mm', Path(__file__), root/'services/gui-cpp/tools/check_tab_activity.py']
    record = dict(scope='Original ring and compact progress drawing produce the ordered quads. An unchanged original Metal vertex/fragment shader renders them through the previously used classic Metal reference encoder. This proves fixed poses, not native scheduling or complete GUI parity.',items=len(entries),shapes=len(document['shapes']),source_sha256={str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},reference_command=reference_command,metal_compile_command=command,input_sha256=hashlib.sha256(payload).hexdigest(),original_paint_sha256=hashlib.sha256(result.stdout).hexdigest(),artifacts={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in ['cases.json','atlas.png']})
    (output/'provenance.json').write_text(json.dumps(record, indent=2)+'\n')
    print('Generated',len(entries),'original ring/capsule poses and',len(document['shapes']),'ordered shapes')


if __name__ == '__main__':
    main()
