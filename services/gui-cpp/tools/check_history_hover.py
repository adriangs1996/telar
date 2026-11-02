"""Compare mixed History row/card hover with unchanged original dispatcher sources."""
import argparse,hashlib,json,math,os,random,struct,subprocess
from pathlib import Path
import check_history_action_capture as capture

reference = r'''
const std = @import("std");
const D = @import("gui/widgets/interaction/Dispatcher.zig");
const Target = @import("gui/widgets/interaction/Target.zig");
const Pointer = @FieldType(@import("telar-window").Input, "pointer");
const io = @import("protocol.zig");
const Action = @import("gui/widgets/interaction/history_action.zig").Action;
pub fn main() !void {
    var dispatcher: D = .{};
    while (true) {
        const incoming = io.operation();
        if (incoming < 0) return;
        const operation: u8 = @intCast(incoming);
        switch (operation) {
            0 => dispatcher = .{},
            1 => {
                const delivered = try io.read(u8) != 0;
                const generation = try io.read(u64);
                _ = dispatcher.begin();
                for (0..5) |_| {
                    const kind = try io.read(u8);
                    const index = try io.read(u64);
                    const revision = try io.read(u64);
                    const bounds = try io.readRect();
                    const present = try io.read(u8) != 0;
                    const enabled = try io.read(u8) != 0;
                    const action: Action = if (kind == 0) .{ .select = .{ .index = @intCast(index), .revision = revision } } else switch (index) { 0 => .copy, 1 => .remove, 2 => .visit_pane, else => unreachable };
                    if (present) _ = try dispatcher.add(.{ .id = .{ .generation = generation }, .namespace = if (kind == 0) 0 else 6, .bounds = bounds, .action = .{ .history = action }, .enabled = enabled, .focusable = false });
                }
                dispatcher.seal();
                dispatcher.present(delivered);
            },
            4 => dispatcher.cancel(),
            else => {
                const button: Pointer.Button = @enumFromInt(try io.read(u8));
                const point = [2]f64{ try io.read(f64), try io.read(f64) };
                const kind: Pointer.Kind = switch (operation) { 2 => .press, 3 => .release, 5 => .move, 6 => .drag, 7 => .leave, else => unreachable };
                _ = dispatcher.probePointer(.{ .kind = kind, .button = button, .x = point[0], .y = point[1] });
            },
        }
        const target: ?Target = if (dispatcher.hovered) |id| dispatcher.maps.presented().find(id) else null;
        var kind: u8 = 0;
        var index: u64 = 0;
        var revision: u64 = 0;
        var generation: u64 = 0;
        if (target) |value| {
            generation = value.id.generation;
            switch (value.action.history) {
                .select => |row| { kind = 1; index = row.index; revision = row.revision; },
                .copy => { kind = 2; index = 0; },
                .remove => { kind = 2; index = 1; },
                .visit_pane => { kind = 2; index = 2; },
                else => unreachable,
            }
        }
        try io.write(kind);
        try io.write(index);
        try io.write(revision);
        try io.write(generation);
    }
}
'''


def frame(generation=11,revision=1,present=31,enabled=31,moved=False,delivered=True,order=(0,1,2,3,4),overlap=False):
    result=struct.pack('<BBQ',1,delivered,generation)
    for slot in order:
        kind,index=(0,slot) if slot<2 else (1,slot-2)
        x=0 if overlap else slot*20
        bounds=(x+(100 if moved else 0),100 if moved else 0,10,10)
        result+=struct.pack('<BQQ4fBB',kind,index,revision if kind==0 else 0,*bounds,bool(present&(1<<slot)),bool(enabled&(1<<slot)))
    return result


def pointer(operation,x=5,y=5,button=0):
    return struct.pack('<BBdd',operation,button,x,y)


def operations(payload):
    count=position=0
    while position<len(payload):
        operation=payload[position]
        position+=1 if operation in (0,4) else (185 if operation==1 else 18)
        count+=1
    assert position==len(payload)
    return count


def cases():
    yield 'initial-no-observation',b'\0'+frame(),(0,0,0,0)
    yield 'row-motion',b'\0'+frame()+pointer(5),(1,0,1,11)
    yield 'stationary-card',b'\0'+frame()+pointer(5,45)+(frame(moved=True)),(2,0,0,11)
    yield 'row-revision-retirement',b'\0'+frame()+pointer(5)+frame(revision=2),(0,0,0,0)
    yield 'card-ignores-row-revision',b'\0'+frame()+pointer(5,45)+frame(revision=2),(2,0,0,11)
    yield 'no-resurrection',b'\0'+frame()+pointer(5,45)+frame(present=27)+frame(),(0,0,0,0)
    yield 'disabled-retains-hover',b'\0'+frame()+pointer(5,45)+frame(enabled=0),(2,0,0,11)
    yield 'generation-retirement',b'\0'+frame()+pointer(5)+frame(generation=12),(0,0,0,0)
    yield 'failed-frame',b'\0'+frame()+pointer(5)+frame(delivered=False,present=0),(1,0,1,11)
    yield 'drag-keeps-action',b'\0'+frame()+pointer(2,45)+pointer(6,5),(2,0,0,11)
    yield 'release-keeps-action',b'\0'+frame()+pointer(2,45)+pointer(3,5),(2,0,0,11)
    yield 'fresh-motion-after-release',b'\0'+frame()+pointer(2,45)+pointer(3,5)+pointer(5,5),(1,0,1,11)
    yield 'focus-cancel',b'\0'+frame()+pointer(2,45)+b'\4',(0,0,0,0)
    yield 'leave',b'\0'+frame()+pointer(5)+pointer(7),(0,0,0,0)
    yield 'outside',b'\0'+frame()+pointer(5,10),(0,0,0,0)
    yield 'overlap-last-wins',b'\0'+frame(overlap=True)+pointer(5),(2,2,0,11)
    yield 'reorder-retains-identity',b'\0'+frame()+pointer(5)+frame(order=(4,3,2,1,0)),(1,0,1,11)
    for slot in (0,2):
        for origin,width in [(capture.f32(0.1),capture.f32(0.2)),(float(1<<24),5.0)]:
            prepared=bytearray(frame(present=1<<slot))
            offset=10+slot*struct.calcsize('<BQQ4fBB')+struct.calcsize('<BQQ')
            prepared[offset:offset+16]=struct.pack('<4f',origin,0,width,10)
            end=origin+width
            for index,x in enumerate([origin,math.nextafter(origin,-math.inf),math.nextafter(end,-math.inf),end,math.nextafter(end,math.inf)]):
                expected=(1,0,1,11) if slot==0 else (2,0,0,11)
                if not origin<=x<end:expected=(0,0,0,0)
                yield f'boundary-{slot}-{origin}-{index}',b'\0'+prepared+pointer(5,x),expected
    for name,x in [('nan',math.nan),('positive-infinity',math.inf),('negative-infinity',-math.inf)]:
        yield name,b'\0'+frame()+pointer(5,x),(0,0,0,0)
    rng=random.Random(0x484F564552)
    for index in range(512):
        generation,revision=11,1
        payload=b'\0'+frame()
        for _ in range(64):
            operation=rng.randrange(8)
            if operation==1:
                generation=generation if rng.randrange(5) else rng.getrandbits(64)
                revision=revision if rng.randrange(3) else rng.getrandbits(64)
                payload+=frame(generation,revision,rng.randrange(32),rng.randrange(32),bool(rng.randrange(2)),bool(rng.randrange(4)),tuple(rng.sample(range(5),5)),rng.randrange(5)==0)
            elif operation==4:payload+=b'\4'
            else:payload+=pointer(5 if operation==0 else operation,rng.choice([0,5,10,25,45,65,85,105,125,145,165,185]),rng.choice([5,105]),rng.randrange(3))
        yield 'random-'+str(index),payload,None


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--compiler',default='clang++')
    parser.add_argument('--sanitizers',action='store_true')
    options=parser.parse_args()
    repository=Path(__file__).resolve().parents[3]
    output=options.output.resolve();output.mkdir(parents=True,exist_ok=False)
    capture.reference=reference
    capture.prepare(repository,output)
    command=[options.compiler,'-std=c++23','-O2','-Wall','-Wextra','-Werror','-I'+str(repository/'services/gui-cpp'),str(repository/'services/gui-cpp/tools/history_hover_probe.cpp'),'-o',str(output/'candidate')]
    if options.sanitizers:command+=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
    with (output/'candidate-build.log').open('w') as log:
        result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
    (output/'candidate-build.json').write_text(json.dumps(dict(command=command,actual_exit=result.returncode),indent=2)+'\n');result.check_returncode()
    corpus=list(cases());payload=b''.join(data for _,data,_ in corpus)
    (output/'input.bin').write_bytes(payload)
    executions=[]
    for name in ('reference','candidate'):
        binary=output/name
        result=subprocess.run([str(binary)],input=payload,capture_output=True,timeout=30)
        (output/(name+'.bin')).write_bytes(result.stdout);(output/(name+'.stderr')).write_bytes(result.stderr)
        executions.append(dict(name=name,actual_exit=result.returncode,binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),output_sha256=hashlib.sha256(result.stdout).hexdigest()))
        assert result.returncode==0,(name,result.stderr.decode(errors='replace'))
    original,candidate=[(output/(name+'.bin')).read_bytes() for name in ('reference','candidate')]
    offset=0;rows=[]
    for name,data,expected in corpus:
        count=operations(data);size=count*25
        a,b=original[offset:offset+size],candidate[offset:offset+size]
        passed=a==b and len(a)==size
        if expected is not None:passed=passed and struct.unpack('<BQQQ',a[-25:])==expected
        rows.append(dict(name=name,operations=count,passed=passed));offset+=size
    record=dict(passed=all(r['passed'] for r in rows) and offset==len(original)==len(candidate),executions=executions,cases=rows,input_sha256=hashlib.sha256(payload).hexdigest(),sanitizers={n:os.environ.get(n) for n in ('ASAN_OPTIONS','UBSAN_OPTIONS','LSAN_OPTIONS')},scope='Mixed row/card semantic hover identity; original Dispatcher sources with narrow type facades; no native raster acceptance')
    (output/'results.json').write_text(json.dumps(record,indent=2)+'\n')
    assert record['passed'],[r for r in rows if not r['passed']][:8]
    print('Passed',len(rows),'original hover sequences;',offset//25,'operations')


if __name__=='__main__':main()
