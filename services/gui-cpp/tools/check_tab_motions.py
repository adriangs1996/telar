"""Compare identity-keyed tab positions and frame deadlines to unchanged Zig motion."""
import argparse,hashlib,json,os,random,shutil,struct,subprocess
from pathlib import Path
from check_history_card import protocol
from check_tab_drag import core

reference=r'''
const core = @import("telar-core");
const animate = @import("animate");
const Motions = @import("TabMotions.zig");
const io = @import("protocol.zig");
pub fn main() !void {
    var motions: Motions = .{};
    var clock: animate.FrameClock = .{};
    while (io.operation() >= 0) {
        const present = try io.read(u8) != 0;
        const kind = try io.read(u8);
        const id = try io.read(u64);
        const workspace: core.WorkspaceLocation = if (kind == 0) .{ .workspace = id } else .{ .worktree = id };
        clock.begin(try io.read(u64));
        clock.interval_ns = try io.read(u64);
        const count = try io.read(u16);
        motions.begin(if (present) workspace else null);
        for (0..count) |_| {
            const tab = try io.read(u64);
            const bounds = try io.readRect();
            const immediate = try io.read(u8) != 0;
            try io.writeRect(motions.place(.{ .id = tab, .bounds = bounds, .immediate = immediate }, &clock));
        }
        motions.finish();
        try io.write(@as(u16, @intCast(motions.len)));
        try io.write(@as(u8, @intFromBool(clock.deadline_ns != null)));
        try io.write(clock.deadline_ns orelse @as(u64, 0));
    }
}
'''

def frame(now,slots,workspace=7,kind=0,present=True,interval=16666667):
    return struct.pack('<BBBQQQH',1,present,kind,workspace,now,interval,len(slots))+b''.join(struct.pack('<Q4fB',*slot) for slot in slots)

def frames():
    initial=[(1,10.,10.,100.,30.,0),(2,112.,10.,80.,30.,0)]
    yield frame(0,initial)
    target=[(2,10.,10.,80.,30.,0),(1,92.,7.,100.,30.,1)]
    for now in (1,45000001,90000001,135000001,180000001):yield frame(now,target)
    target=[(2,50.,20.,120.,45.,0),(1,10.,10.,100.,30.,0)]
    for now in (180000002,200000000,250000000):yield frame(now,target)
    target=[(2,10.,10.,80.,30.,0)]
    for now in (250000001,280000000,430000001):yield frame(now,target)
    for workspace,kind in ((8,0),(8,1),(7,0)):
        yield frame(430000002,target,workspace,kind)
        yield frame(430000003,[],workspace,kind)
        yield frame(430000004,target,workspace,kind)
    rng=random.Random(0x5441424d4f54494f);now=500000000
    for _ in range(1024):
        now+=rng.choice((0,1,1000000,16666667,45000000,180000000,250000000))
        ids=rng.sample(range(1,81),rng.randrange(81));slots=[(id,rng.uniform(-100,1000),rng.uniform(-20,60),rng.uniform(0,400),rng.uniform(0,80),rng.randrange(2)) for id in ids]
        yield frame(now,slots,rng.choice((7,8)),rng.randrange(2),rng.choice((True,True,True,False)),rng.choice((0,1,16666667,33333334)))
    now=2**64-100000000
    yield frame(now,initial)
    yield frame(now+1,target)
    yield frame(2**64-1,target)

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--compiler',default='clang++');parser.add_argument('--sanitizers',action='store_true');a=parser.parse_args();repo=Path(__file__).resolve().parents[3];service=repo/'services/gui-cpp';out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);root=out/'original';root.mkdir()
    names={'TabMotions.zig':'src/gui/widgets/TabMotions.zig','TabSlot.zig':'src/gui/widgets/TabSlot.zig','Transition.zig':'lib/animate/Transition.zig','FrameClock.zig':'lib/animate/FrameClock.zig'}
    for name,source in names.items():shutil.copy2(repo/source,root/name)
    for name,source in {'core.zig':core,'gfx.zig':'pub const Rect = struct { x:f32=0,y:f32=0,width:f32=0,height:f32=0 };\n','animate.zig':'pub const FrameClock = @import("FrameClock.zig");\npub const Transition = @import("Transition.zig");\n','protocol.zig':protocol.replace('@import("facades.zig").Rect','@import("gfx").Rect'),'probe.zig':reference}.items():(root/name).write_text(source)
    aliases=[('telar-core','core.zig'),('gfx','gfx.zig'),('animate','animate.zig')];command=['zig','build-exe','-O','ReleaseSafe','-lc']
    for name,_ in aliases:command+=['--dep',name]
    command+=['-Mroot='+str(root/'probe.zig')]+['-M'+name+'='+str(root/file) for name,file in aliases]+['-femit-bin='+str(out/'reference')]
    candidate=[a.compiler,'-std=c++23','-O2','-ffp-contract=off','-Wall','-Wextra','-Werror','-I'+str(service),'-I'+str(repo/'dlls/telar-client/include'),str(service/'tools/tab_motions_probe.cpp'),'-o',str(out/'candidate')]
    if a.sanitizers:candidate+=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
    for name,command in [('reference',command),('candidate',candidate)]:
        r=subprocess.run(command,capture_output=True);(out/(name+'-build.log')).write_bytes(r.stdout+r.stderr);(out/(name+'-build.json')).write_text(json.dumps(dict(command=command,actual_exit=r.returncode),indent=2)+'\n');r.check_returncode()
    samples=list(frames());payload=b''.join(samples);(out/'input.bin').write_bytes(payload);records=[]
    for name in ('reference','candidate'):
        r=subprocess.run([str(out/name)],input=payload,capture_output=True,timeout=120);(out/(name+'.bin')).write_bytes(r.stdout);(out/(name+'.stderr')).write_bytes(r.stderr);records.append(dict(name=name,actual_exit=r.returncode,binary_sha256=hashlib.sha256((out/name).read_bytes()).hexdigest()));r.check_returncode()
    expected=(out/'reference.bin').read_bytes();actual=(out/'candidate.bin').read_bytes();result=dict(passed=expected==actual,frames=len(samples),executions=records,input_sha256=hashlib.sha256(payload).hexdigest(),output_sha256=hashlib.sha256(actual).hexdigest(),unchanged_original_sha256={n:hashlib.sha256((repo/n).read_bytes()).hexdigest() for n in names.values()},scope='Unchanged original TabMotions/TabSlot/Transition/FrameClock; byte-exact positions and next-frame deadlines. Narrow core/gfx aliases, no GPU or full-client performance claim.',sanitizers={n:os.environ.get(n) for n in ('ASAN_OPTIONS','UBSAN_OPTIONS','LSAN_OPTIONS')});(out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    assert result['passed'],next((i for i,(x,y) in enumerate(zip(expected,actual)) if x!=y),min(len(expected),len(actual)));print('Matched',len(samples),'original motion frames',flush=True)

if __name__=='__main__':main()
