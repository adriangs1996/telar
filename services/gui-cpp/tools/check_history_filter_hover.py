"""Compare mixed History filter/row/card/footer hover with unchanged original dispatcher sources."""
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
                for (0..17) |_| {
                    const kind = try io.read(u8);
                    const index = try io.read(u64);
                    const revision = try io.read(u64);
                    const selection = try io.read(u64);
                    const bounds = try io.readRect();
                    const present = try io.read(u8) != 0;
                    const enabled = try io.read(u8) != 0;
                    const action: Action = switch (kind) {
                        0 => .{ .select = .{ .index = @intCast(index), .revision = revision } },
                        1 => switch (index) { 0 => .copy, 1 => .remove, 2 => .visit_pane, else => unreachable },
                        2 => switch (index) {
                            1 => .{ .submit = .{ .index = @intCast(selection), .revision = revision } },
                            2 => .{ .submit_alternate = .{ .index = @intCast(selection), .revision = revision } },
                            3 => .toggle_inspection,
                            4 => .visit_pane,
                            else => unreachable,
                        },
                        3 => switch (index) {
                            0 => .{ .select_scope = .global }, 1 => .{ .select_scope = .workspace },
                            2 => .{ .select_scope = .cwd }, 3 => .{ .select_scope = .pane },
                            4 => .{ .select_author = .human }, 5 => .{ .select_author = .agent },
                            6 => .{ .select_author = .all }, 7 => .toggle_failed, else => unreachable,
                        },
                        else => unreachable,
                    };
                    if (present) _ = try dispatcher.add(.{ .id = .{ .generation = generation }, .namespace = switch (kind) { 0, 3 => 0, 1 => 6, 2 => 5, else => unreachable }, .bounds = bounds, .action = .{ .history = action }, .enabled = enabled, .focusable = false });
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
        var selection: u64 = 0;
        if (target) |value| {
            generation = value.id.generation;
            if (value.namespace == 5) {
                kind = 3;
                switch (value.action.history) {
                    .submit => |choice| { index = 1; selection = choice.index; revision = choice.revision; },
                    .submit_alternate => |choice| { index = 2; selection = choice.index; revision = choice.revision; },
                    .toggle_inspection => { index = 3; },
                    .visit_pane => { index = 4; },
                    else => unreachable,
                }
            } else {
                switch (value.action.history) {
                    .select_scope => |scope| { kind = 4; index = switch (scope) { .global => 0, .workspace => 1, .cwd => 2, .pane => 3 }; },
                    .select_author => |author| { kind = 4; index = switch (author) { .human => 4, .agent => 5, .all => 6 }; },
                    .toggle_failed => { kind = 4; index = 7; },
                    .select => |row| { kind = 1; index = row.index; revision = row.revision; },
                    .copy => { kind = 2; index = 0; },
                    .remove => { kind = 2; index = 1; },
                    .visit_pane => { kind = 2; index = 2; },
                    else => unreachable,
                }
            }
        }
        try io.write(kind);
        try io.write(index);
        try io.write(revision);
        try io.write(generation);
        try io.write(selection);
    }
}
'''


TARGETS=17
DRAW_ORDER=tuple(range(9,13))+(16,)+tuple(range(13,16))+tuple(range(9))
FRAME_BYTES=10+TARGETS*struct.calcsize('<BQQQ4fBB')
OUTPUT_BYTES=struct.calcsize('<BQQQQ')
ALL_TARGETS=(1<<TARGETS)-1


def frame(generation=11,revision=1,selection=0,present=ALL_TARGETS,enabled=ALL_TARGETS,moved=False,delivered=True,order=DRAW_ORDER,overlap=False):
    result=struct.pack('<BBQ',1,delivered,generation)
    for slot in order:
        if slot<2:kind,index=0,slot
        elif slot<5:kind,index=1,slot-2
        elif slot<9:kind,index=2,slot-4
        else:kind,index=3,slot-9
        x=0 if overlap else slot*20
        bounds=(x+(100 if moved else 0),100 if moved else 0,10,10)
        result+=struct.pack('<BQQQ4fBB',kind,index,revision if kind!=1 else 0,selection if kind==2 else 0,*bounds,bool(present&(1<<slot)),bool(enabled&(1<<slot)))
    return result


def pointer(operation,x=5,y=5,button=0):
    return struct.pack('<BBdd',operation,button,x,y)


def operations(payload):
    count=position=0
    while position<len(payload):
        operation=payload[position]
        position+=1 if operation in (0,4) else (FRAME_BYTES if operation==1 else 18)
        count+=1
    assert position==len(payload)
    return count


def identity(slot,revision=1,generation=11,selection=0):
    if slot<2:return (1,slot,revision,generation,0)
    if slot<5:return (2,slot-2,0,generation,0)
    if slot<9:return (3,slot-4,revision if slot<7 else 0,generation,selection if slot<7 else 0)
    return (4,slot-9,0,generation,0)


def cases():
    none=(0,0,0,0,0)
    yield 'initial-no-observation',b'\0'+frame(),none
    for slot in range(TARGETS):
        payload=b'\0'+frame()+pointer(5,slot*20+5)
        yield 'motion-'+str(slot),payload,identity(slot)
        yield 'stationary-move-'+str(slot),payload+frame(moved=True),identity(slot)
        yield 'disabled-'+str(slot),payload+frame(enabled=0),identity(slot)
        yield 'retirement-'+str(slot),payload+frame(present=ALL_TARGETS^(1<<slot))+frame(),none
        yield 'generation-'+str(slot),payload+frame(generation=12),none
        yield 'failed-delivery-'+str(slot),payload+frame(delivered=False,present=0),identity(slot)
        yield 'leave-'+str(slot),payload+pointer(7),none
        yield 'cancel-'+str(slot),payload+b'\4',none
        yield 'retained-release-'+str(slot),payload+pointer(2,slot*20+5)+pointer(3,500),identity(slot)
        yield 'revision-'+str(slot),payload+frame(revision=2),none if slot in (0,1,5,6) else identity(slot)
        yield 'selection-'+str(slot),payload+frame(selection=8),none if slot in (5,6) else identity(slot)
    yield 'overlap-footer-last',b'\0'+frame(overlap=True)+pointer(5),identity(8)
    yield 'visit-namespaces-distinct',b'\0'+frame(overlap=True,present=(1<<4)|(1<<8))+pointer(5)+frame(overlap=True,present=1<<4),none
    yield 'namespace-fresh-move',b'\0'+frame(overlap=True,present=(1<<4)|(1<<8))+pointer(5)+frame(overlap=True,present=1<<4)+pointer(5),identity(4)
    yield 'footer-reordered',b'\0'+frame()+pointer(5,105)+frame(order=tuple(reversed(range(TARGETS)))),identity(5)
    for slot in (0,2,5,7,9,13,16):
        for origin,width in [(capture.f32(0.1),capture.f32(0.2)),(float(1<<24),5.0)]:
            prepared=bytearray(frame(present=1<<slot))
            offset=10+DRAW_ORDER.index(slot)*struct.calcsize('<BQQQ4fBB')+struct.calcsize('<BQQQ')
            prepared[offset:offset+16]=struct.pack('<4f',origin,0,width,10)
            end=origin+width
            for index,x in enumerate([origin,math.nextafter(origin,-math.inf),math.nextafter(end,-math.inf),end,math.nextafter(end,math.inf)]):
                expected=identity(slot) if origin<=x<end else none
                yield f'boundary-{slot}-{origin}-{index}',b'\0'+prepared+pointer(5,x),expected
    for name,x in [('nan',math.nan),('positive-infinity',math.inf),('negative-infinity',-math.inf)]:
        yield name,b'\0'+frame()+pointer(5,x),none
    rng=random.Random(0x46494C544552)
    for index in range(512):
        generation,revision,selection=11,1,0;payload=b'\0'+frame()
        for _ in range(64):
            operation=rng.randrange(8)
            if operation==1:
                generation=generation if rng.randrange(5) else rng.getrandbits(64)
                revision=revision if rng.randrange(3) else rng.getrandbits(64)
                selection=selection if rng.randrange(3) else rng.randrange(100)
                payload+=frame(generation,revision,selection,rng.randrange(ALL_TARGETS+1),rng.randrange(ALL_TARGETS+1),bool(rng.randrange(2)),bool(rng.randrange(4)),tuple(rng.sample(range(TARGETS),TARGETS)),rng.randrange(5)==0)
            elif operation==4:payload+=b'\4'
            else:payload+=pointer(5 if operation==0 else operation,rng.choice([0,5,10,25,45,65,85,105,125,145,165,185,205,225,245,265,285,305,325]),rng.choice([5,105]),rng.randrange(3))
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
    command=[options.compiler,'-std=c++23','-O2','-Wall','-Wextra','-Werror','-I'+str(repository/'services/gui-cpp'),str(repository/'services/gui-cpp/tools/history_filter_hover_probe.cpp'),'-o',str(output/'candidate')]
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
        count=operations(data);size=count*OUTPUT_BYTES
        a,b=original[offset:offset+size],candidate[offset:offset+size]
        passed=a==b and len(a)==size
        if expected is not None:passed=passed and struct.unpack('<BQQQQ',a[-OUTPUT_BYTES:])==expected
        rows.append(dict(name=name,operations=count,passed=passed));offset+=size
    record=dict(passed=all(r['passed'] for r in rows) and offset==len(original)==len(candidate),executions=executions,cases=rows,input_sha256=hashlib.sha256(payload).hexdigest(),sanitizers={n:os.environ.get(n) for n in ('ASAN_OPTIONS','UBSAN_OPTIONS','LSAN_OPTIONS')},scope='Mixed filter/row/card/footer semantic hover identity; original Dispatcher sources with narrow type facades; no native raster acceptance')
    (output/'results.json').write_text(json.dumps(record,indent=2)+'\n')
    assert record['passed'],[r for r in rows if not r['passed']][:8]
    print('Passed',len(rows),'original hover sequences;',offset//OUTPUT_BYTES,'operations')


if __name__=='__main__':main()
