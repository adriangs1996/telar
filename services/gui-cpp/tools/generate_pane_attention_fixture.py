import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

from check_pane_attention import alpha, frame, geometry, prepare


phases = [0, 90_000_000, 180_000_000, 360_000_000]
colors = [0xE8C56A, 0xF27C7C]


def entries():
    records = []
    for ratio in [0.5, 1, 1.25, 2]:
        for rgb in colors:
            for size in [(1, 1), (3, 4), (12, 17), (32, 24), (64, 40), (70.5, 44.5)]:
                index = len(records)
                records.append(dict(rect=[(index%8)*80+8.25, (index//8)*64+3.5, *size], ratio=ratio, rgb=rgb, pane_id=index+1))
    return records


def paints(data, count):
    status_bytes = struct.calcsize('<BQI')
    offset = (struct.calcsize('<f') + status_bytes)*count + status_bytes
    shapes = []
    for _ in range(count):
        present = data[offset]
        offset += 1
        if present:
            values = struct.unpack_from('<14f', data, offset)
            offset += struct.calcsize('<14f')
            shapes.append(dict(rect=values[:4], radius=values[4], borderWidth=values[5], fill=values[6:10], border=values[10:14], opacity=1))
        offset += status_bytes
    offset += status_bytes
    if offset != len(data):
        raise RuntimeError('Unexpected original attention paint payload size')
    return shapes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work-dir',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.work_dir.resolve();work.mkdir(parents=True,exist_ok=False)
    output = options.output_dir.resolve();output.mkdir(parents=True,exist_ok=True)
    reference = prepare(root,work)
    helper = work/'metal-reference'
    metal_command = ['clang++','-std=c++23','-fobjc-arc','-Wall','-Wextra','-Werror','-framework','Foundation','-framework','Metal','-framework','ImageIO','-framework','CoreGraphics',str(root/'services/gui-cpp/tools/rounded_rectangle_reference.mm'),'-o',str(helper)]
    subprocess.run(metal_command,check=True)
    items = entries()
    seed = b'\x04'+frame(0)+b''.join(alpha(item['pane_id'],1) for item in items)+b'\x02'
    shader = root/'lib/window/shaders/quad.metal'
    frames = []
    for now in phases:
        payload = seed+frame(now)
        for item in items:
            color = [((item['rgb']>>shift)&255)/255 for shift in [16,8,0]]+[1]
            payload += geometry(item['rect'],item['ratio'],color,(item['pane_id'],1),True)
        payload += b'\x02'
        result = subprocess.run([work/'original'],input=payload,capture_output=True,check=True)
        document = dict(width=640,height=384,background=[16/255,16/255,16/255,1],items=items,shapes=paints(result.stdout,len(items)))
        name = f'alpha-{now}.png'
        request = work/f'alpha-{now}.json';request.write_text(json.dumps(document,indent=2)+'\n')
        subprocess.run([helper,shader,request,output/name],check=True)
        frames.append(dict(now_ns=now,alpha=now/phases[-1],capture=name,shapes=document['shapes'],paint_sha256=hashlib.sha256(result.stdout).hexdigest(),input_sha256=hashlib.sha256(payload).hexdigest()))
    document = dict(width=640,height=384,background=[16/255,16/255,16/255,1],items=items,frames=frames)
    (output/'cases.json').write_text(json.dumps(document,indent=2)+'\n')
    paths=['src/gui/widgets/PaneDecorations.zig','src/gui/widgets/Canvas.zig','src/gui/widgets/RingFades.zig','src/gui/widgets/RingFade.zig','lib/animate/FrameClock.zig','lib/animate/Transition.zig','lib/window/shaders/quad.metal','services/gui-cpp/tools/rounded_rectangle_reference.mm','services/gui-cpp/tools/check_pane_attention.py','services/gui-cpp/tools/generate_pane_attention_fixture.py']
    metadata=dict(scope='Original attention geometry, retained fade table and frame clock produce ordered rounded shapes at fixed timestamps. The unchanged original Metal shader renders each atlas through the existing reference encoder. This proves fixed poses; live window scheduling and complete GUI parity remain separate.',items=len(items),phases=phases,reference_command=reference,metal_compile_command=metal_command,source_sha256={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in paths},artifacts={name:hashlib.sha256((output/name).read_bytes()).hexdigest() for name in ['cases.json',*[frame['capture'] for frame in frames]]})
    (output/'provenance.json').write_text(json.dumps(metadata,indent=2)+'\n');print('Generated',len(items),'original attention rings at',len(phases),'fixed timestamps')


if __name__=='__main__':
    main()
