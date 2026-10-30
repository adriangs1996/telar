"""Compare History selection expansion with the original motion and frame clock."""
from pathlib import Path
import argparse,hashlib,json,os,random,shutil,struct,subprocess
from check_history_card import protocol

reference=r'''
const std = @import("std");
const Motion = @import("gui/widgets/overlays/SelectionMotion.zig");
const Position = @import("gui/widgets/overlays/HistoryPosition.zig");
const animate = @import("animate");
const io = @import("protocol.zig");
pub fn main() !void {
    var motion: Motion = .{};
    var clock: animate.FrameClock = .{};
    while (true) {
        const incoming = io.operation();
        if (incoming < 0) return;
        if (incoming == 0) { motion = .{}; clock = .{}; continue; }
        const has_generation = try io.read(u8) != 0;
        const generation = try io.read(u64);
        const has_selection = try io.read(u8) != 0;
        const selected: Position = .{ .index = try io.read(u16), .id = try io.read(u64) };
        const animated = try io.read(u8) != 0;
        const now = try io.read(u64);
        clock.interval_ns = try io.read(u64);
        clock.begin(now);
        const expansion = motion.sample(if (has_generation) generation else null, if (has_selection) selected else null, if (animated) &clock else null);
        try io.write(expansion.open);
        try io.write(@as(u8, @intFromBool(expansion.leaving != null)));
        try io.write(if (expansion.leaving) |row| row.index else @as(u16, 0));
        try io.write(if (expansion.leaving) |row| row.id else @as(u64, 0));
        try io.write(expansion.leaving_open);
        try io.write(@as(u8, @intFromBool(clock.deadline_ns != null)));
        try io.write(clock.deadline_ns orelse 0);
    }
}
'''


def prepare(repository,output):
    root=output/'original';root.mkdir()
    names=['src/gui/widgets/overlays/'+n for n in ('SelectionMotion.zig','HistoryPosition.zig','HistoryExpansion.zig')]+['lib/animate/Transition.zig','lib/animate/FrameClock.zig']
    identities={}
    for name in names:
        path=repository/name
        target=root/(name.removeprefix('src/') if name.startswith('src/') else Path(name).name)
        target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,target)
        identities[name]=hashlib.sha256(path.read_bytes()).hexdigest()
    (root/'animate.zig').write_text('pub const FrameClock = @import("FrameClock.zig");\npub const Transition = @import("Transition.zig");\n')
    (root/'protocol.zig').write_text(protocol)
    (root/'facades.zig').write_text('pub const Rect = struct { x:f32, y:f32, width:f32, height:f32 };\n')
    (root/'probe.zig').write_text(reference)
    command=['zig','build-exe','-O','ReleaseSafe','-lc','--dep','animate','-Mroot='+str(root/'probe.zig'),'-Manimate='+str(root/'animate.zig'),'-femit-bin='+str(output/'reference')]
    with (output/'reference-build.log').open('w') as log:r=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
    (output/'reference-build.json').write_text(json.dumps(dict(command=command,actual_exit=r.returncode,unchanged_source_sha256=identities),indent=2)+'\n');r.check_returncode()


def sample(now,index=0,identity=1,generation=11,animated=True,interval=16_666_667,selected=True):
    return struct.pack('<BBQBHQBQQ',1,generation is not None,generation or 0,selected,index,identity,animated,now,interval)


def cases():
    yield 'initial-settled',b'\0'+sample(100)
    yield 'selection-first-frame-zero',b'\0'+sample(100)+sample(200,1,2)
    for delta in (0,1,1_000_000,16_666_667,70_000_000,139_999_999,140_000_000,140_000_001):
        yield 'opening-'+str(delta),b'\0'+sample(100)+sample(200,1,2)+sample(200+delta,1,2)
    yield 'same-index-new-entry',b'\0'+sample(100)+sample(200,1,2)+sample(1000,1,3)
    yield 'generation-change',b'\0'+sample(100)+sample(200,1,2)+sample(300,2,3,generation=12)
    yield 'generation-cleared',b'\0'+sample(100)+sample(200,1,2)+sample(300,generation=None)
    yield 'no-selection',b'\0'+sample(100)+sample(200,1,2)+sample(300,selected=False)
    yield 'no-animation',b'\0'+sample(100)+sample(200,1,2,animated=False)
    yield 'interrupted',b'\0'+sample(100)+sample(200,1,2)+sample(35_000_200,2,3)+sample(70_000_200,2,3)
    yield 'time-reversal',b'\0'+sample(100)+sample(200,1,2)+sample(50,1,2)
    yield 'saturation',b'\0'+sample((1<<64)-200)+sample((1<<64)-100,1,2)+sample((1<<64)-1,1,2)
    rng=random.Random(0x53454C454354)
    for index in range(512):
        now=0;payload=b'\0'
        for _ in range(64):
            now=min((1<<64)-1,now+rng.randrange(50_000_000))
            payload+=sample(now,rng.randrange(5),rng.randrange(10),None if rng.randrange(20)==0 else rng.randrange(3),rng.randrange(10)!=0,rng.choice([1,8_333_334,16_666_667,50_000_000]),rng.randrange(20)!=0)
        yield 'random-'+str(index),payload


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--compiler',default='clang++');parser.add_argument('--sanitizers',action='store_true');options=parser.parse_args()
    repository=Path(__file__).resolve().parents[3];output=options.output.resolve();output.mkdir(parents=True,exist_ok=False);prepare(repository,output)
    command=[options.compiler,'-std=c++23','-O2','-ffp-contract=off','-Wall','-Wextra','-Werror','-I'+str(repository/'services/gui-cpp'),str(repository/'services/gui-cpp/tools/history_selection_motion_probe.cpp'),'-o',str(output/'candidate')]
    if options.sanitizers:command+=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
    with (output/'candidate-build.log').open('w') as log:r=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
    (output/'candidate-build.json').write_text(json.dumps(dict(command=command,actual_exit=r.returncode),indent=2)+'\n');r.check_returncode()
    corpus=list(cases());payload=b''.join(data for _,data in corpus);(output/'input.bin').write_bytes(payload);executions=[]
    for name in ('reference','candidate'):
        binary=output/name;r=subprocess.run([str(binary)],input=payload,capture_output=True,timeout=30)
        (output/(name+'.bin')).write_bytes(r.stdout);(output/(name+'.stderr')).write_bytes(r.stderr)
        executions.append(dict(name=name,actual_exit=r.returncode,binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),output_sha256=hashlib.sha256(r.stdout).hexdigest()));assert r.returncode==0,(name,r.stderr.decode(errors='replace'))
    a,b=[(output/(name+'.bin')).read_bytes() for name in ('reference','candidate')];offset=0;rows=[]
    for name,data in corpus:
        position=count=0
        while position<len(data):
            if data[position]==0:position+=1
            else:position+=struct.calcsize('<BBQBHQBQQ');count+=1
        assert position==len(data)
        size=count*28;rows.append(dict(name=name,operations=count,passed=a[offset:offset+size]==b[offset:offset+size] and len(b[offset:offset+size])==size));offset+=size
    result=dict(passed=all(row['passed'] for row in rows) and offset==len(a)==len(b),executions=executions,cases=rows,input_sha256=hashlib.sha256(payload).hexdigest(),sanitizers={n:os.environ.get(n) for n in ('ASAN_OPTIONS','UBSAN_OPTIONS','LSAN_OPTIONS')})
    (output/'results.json').write_text(json.dumps(result,indent=2)+'\n');assert result['passed'],[r for r in rows if not r['passed']][:8]
    print('Passed',len(rows),'original selection-motion sequences;',offset//28,'samples')


if __name__=='__main__':main()
