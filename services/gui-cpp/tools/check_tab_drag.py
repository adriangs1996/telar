"""Compare bounded tab drag state and captured drop slots to unchanged Zig sources."""
import argparse,hashlib,json,os,random,re,shutil,struct,subprocess
from pathlib import Path
from check_history_card import protocol

reference=r'''
const core = @import("telar-core");
const data = @import("model");
const Drag = @import("client/TabDrag.zig");
const Slots = @import("gui/interaction/TabDropSlots.zig");
const Registry = @import("gui/interaction/Registry.zig");
const Move = @import("client/TabMoveIntent.zig");
const io = @import("protocol.zig");
fn workspace() !core.WorkspaceLocation {
    const kind = try io.read(u8);
    const id = try io.read(u64);
    return if (kind == 0) .{ .workspace = id } else .{ .worktree = id };
}
fn point() ![2]f64 { return .{ try io.read(f64), try io.read(f64) }; }
fn target() !?core.TabMoveTarget {
    const present = try io.read(u8) != 0;
    const relative = try io.read(u8) != 0;
    const id = try io.read(u64);
    const direction: core.TabMoveDirection = @enumFromInt(try io.read(u8));
    return if (present) .{ .relative_to = if (relative) id else null, .direction = direction } else null;
}
fn writeSource(source: ?core.TabLocation) !void {
    try io.write(@as(u8, @intFromBool(source != null)));
    const location: core.TabLocation = source orelse .{ .workspace = .{ .workspace = 0 }, .tab_id = 0 };
    try io.write(@as(u8, @intFromEnum(location.workspace)));
    try io.write(switch (location.workspace) { inline else => |id| id });
    try io.write(location.tab_id);
}
fn writeTarget(value: ?core.TabMoveTarget) !void {
    try io.write(@as(u8, @intFromBool(value != null)));
    try io.write(@as(u8, @intFromBool(value != null and value.?.relative_to != null)));
    try io.write(if (value) |v| v.relative_to orelse @as(u64, 0) else @as(u64, 0));
    try io.write(@as(u8, if (value) |v| @intFromEnum(v.direction) else 0));
}
pub fn main() !void {
    var drag: Drag = .{};
    var slots: Slots = .{};
    while (true) {
        const incoming = io.operation();
        if (incoming < 0) { return; }
        var move: ?Move = null;
        var found: ?core.TabMoveTarget = null;
        switch (incoming) {
            0 => { drag = .{}; slots = .{}; },
            1 => {
                const location: core.TabLocation = .{ .workspace = try workspace(), .tab_id = try io.read(u64) };
                drag.begin(location, try point());
            },
            2 => drag.cancel(),
            3 => {
                const position = try point();
                drag.update(position, try target());
            },
            4 => move = drag.finish(),
            5 => {
                var model: data.ClientModel = .{};
                model.name_prompt.value = try io.read(u8) != 0;
                const present = try io.read(u8) != 0;
                const location = try workspace();
                model.workspace = if (present) location else null;
                model.tabs.len = try io.read(u16);
                for (model.tabs.ids[0..model.tabs.len]) |*id| { id.* = try io.read(u64); }
                drag.validate(&model);
            },
            6 => {
                var registry: Registry = .{};
                registry.len = try io.read(u16);
                for (registry.targets[0..registry.len]) |*entry| {
                    const id = try io.read(u64);
                    entry.bounds = try io.readRect();
                    entry.layer = try io.read(u8);
                    entry.enabled = try io.read(u8) != 0;
                    const select = try io.read(u8) != 0;
                    entry.action = if (select) .{ .intent = .{ .select_tab = id } } else .other;
                }
                slots.capture(&registry);
            },
            7 => {
                const position = try point();
                found = slots.at(.{ .x = position[0], .y = position[1] });
            },
            else => return error.InvalidOperation,
        }
        try io.write(@as(u8, @intFromBool(drag.captured)));
        try io.write(@as(u8, @intFromBool(drag.dragging)));
        try writeSource(drag.source);
        try writeTarget(drag.destination);
        try writeSource(if (move) |m| m.location else null);
        try writeTarget(if (move) |m| .{ .relative_to = m.relative_to, .direction = m.direction } else null);
        try writeTarget(found);
        try io.write(@as(u16, @intCast(slots.len)));
    }
}
'''

core='''pub const TabId = u64;
pub const max_tabs_per_workspace = 64;
pub const WorkspaceLocation = union(enum) { workspace: u64, worktree: u64 };
pub const TabLocation = struct { workspace: WorkspaceLocation, tab_id: u64 };
pub const TabMoveDirection = enum { previous, next };
pub const TabMoveTarget = struct { direction: TabMoveDirection, relative_to: ?TabId = null };
'''
model='''const core = @import("telar-core");
const Tabs = struct {
    ids: [core.max_tabs_per_workspace]u64 = undefined,
    len: usize = 0,
    pub fn find(self: *const @This(), id: u64) ?usize {
        for (self.ids[0..self.len], 0..) |value, index| {
            if (value == id) { return index; }
        }
        return null;
    }
};
const NamePrompt = struct {
    value: bool = false,
    pub fn active(self: *const @This()) bool { return self.value; }
};
pub const ClientModel = struct { workspace: ?core.WorkspaceLocation = null, tabs: Tabs = .{}, name_prompt: NamePrompt = .{} };
'''
registry='''const core = @import("telar-core");
const gfx = @import("gfx");
const Target = struct { layer: u8 = 0, enabled: bool = true, bounds: gfx.Rect = .{}, action: union(enum) { intent: union(enum) { select_tab: core.TabId }, other } = .other };
targets: [256]Target = undefined,
len: usize = 0,
'''

def begin(tab=1,kind=0,workspace=7,x=0,y=0):
    return struct.pack('<BBQQdd',1,kind,workspace,tab,x,y)

def target(relative=2,direction=1,present=True):
    return struct.pack('<BBQB',present,relative is not None,relative or 0,direction)

def update(x,y=0,relative=2,direction=1,present=True):
    return struct.pack('<Bdd',3,x,y)+target(relative,direction,present)

def validate(tabs=(1,2),workspace=7,kind=0,present=True,naming=False):
    return struct.pack('<BBBBQH',5,naming,present,kind,workspace,len(tabs))+b''.join(struct.pack('<Q',i) for i in tabs)

def capture(entries):
    return struct.pack('<BH',6,len(entries))+b''.join(struct.pack('<Q4fBBB',*row) for row in entries)

def cases():
    for position in (.9999999999999999,1,1.0000000000000002,-1):
        yield 'horizontal-threshold-'+str(position),[b'\0',begin(),update(position),b'\4']
        yield 'vertical-threshold-'+str(position),[b'\0',begin(),update(0,position),b'\4']
    yield 'source-is-not-destination',[b'\0',begin(),update(2,relative=1),b'\4']
    yield 'single-step-target',[b'\0',begin(),update(2,relative=None),b'\4']
    yield 'cancel-is-a-sink',[b'\0',begin(),update(2),b'\2',update(3),b'\4',b'\4']
    yield 'reenter-after-leave',[b'\0',begin(),update(2),update(3,present=False),update(4,direction=0),b'\4']
    yield 'source-survives-focus',[b'\0',begin(),update(2),validate(tabs=(2,1,3)),b'\4']
    for name,operation in [('workspace-replaced',validate(workspace=8)),('workspace-kind-replaced',validate(kind=1)),('workspace-gone',validate(present=False)),('source-retired',validate(tabs=(2,3))),('name-prompt',validate(naming=True))]:
        yield name,[b'\0',begin(),update(2),operation,update(3),b'\4']
    yield 'restart-replaces-old-capture',[b'\0',begin(),update(2),begin(3,x=10),update(12,relative=2),b'\4']
    entries=[(i+1,i*22.,3.,20.,10.,0,1,1) for i in range(64)]
    for size in (0,1,2,63,64,65,80):
        slots=entries+[(i+100,2000.+i*10,3.,8.,10.,0,1,1) for i in range(max(0,size-64))]
        yield 'bounded-capture-'+str(size),[b'\0',capture(slots[:size]),*[struct.pack('<Bdd',7,x,y) for x,y in ((0,3),(10,3),(20,3),(21,3),(22,3),(1390,3),(2000,3),(5,2.99),(5,13))]]
    mixed=[(1,0.,0.,10.,10.,1,1,1),(2,10.,0.,10.,10.,0,0,1),(3,20.,0.,10.,10.,0,1,0),(4,30.,0.,10.,10.,0,1,1),(5,50.,0.,10.,10.,0,1,1)]
    yield 'layer-disabled-and-gap-ties',[b'\0',capture(mixed),*[struct.pack('<Bdd',7,x,5.) for x in (0,10,20,29,30,34.999,35,39.999,40,45,49.999,50,55,59.999,60)]]
    rng=random.Random(0x54414244524147)
    for index in range(1024):
        operations=[b'\0',begin(tab=rng.randrange(1,5),kind=rng.randrange(2),workspace=rng.choice((0,7,2**64-1)),x=rng.uniform(-10,10),y=rng.uniform(-10,10))]
        for _ in range(32):
            operation=rng.randrange(6)
            if operation<3:operations.append(update(rng.uniform(-16,16),rng.uniform(-16,16),rng.choice((None,1,2,3,2**64-1)),rng.randrange(2),rng.choice((True,False))))
            elif operation==3:operations.append(validate(tabs=tuple(rng.sample(range(1,6),rng.randrange(6))),workspace=rng.choice((0,7,2**64-1)),kind=rng.randrange(2),present=rng.choice((True,False)),naming=rng.choice((True,False))))
            else:operations.append(b'\2' if operation==4 else b'\4')
        yield 'mixed-gesture-'+str(index),operations
    for index in range(256):
        entries=[(slot+1,rng.uniform(-100,100),rng.uniform(-10,10),rng.uniform(0,40),rng.uniform(0,20),rng.randrange(3),rng.randrange(2),rng.randrange(2)) for slot in range(rng.randrange(81))]
        yield 'mixed-slots-'+str(index),[b'\0',capture(entries),*[struct.pack('<Bdd',7,rng.uniform(-120,140),rng.uniform(-12,32)) for _ in range(32)]]


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--compiler',default='clang++');parser.add_argument('--sanitizers',action='store_true');a=parser.parse_args();repo=Path(__file__).resolve().parents[3];service=repo/'services/gui-cpp';out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);root=out/'original';root.mkdir()
    names={'client/TabDrag.zig':'src/client/workspace/TabDrag.zig','client/TabMoveIntent.zig':'src/client/workspace/TabMoveIntent.zig','gui/interaction/TabDropSlots.zig':'src/gui/widgets/interaction/TabDropSlots.zig','gui/TabSlot.zig':'src/gui/widgets/TabSlot.zig'}
    for dest,src in names.items():
        path=root/dest;path.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(repo/src,path)
    limits=(repo/'src/core/schema/types.zig').read_text();maximum=int(re.search(r'pub const max_tabs_per_workspace = (\d+);',limits).group(1));assert maximum==64
    for name,source in {'core.zig':core,'model.zig':model,'gfx.zig':'pub const Rect = struct { x:f32=0,y:f32=0,width:f32=0,height:f32=0 };\n','window.zig':'pub const Input = union(enum) { pointer: struct { x:f64,y:f64 } };\n','gui/interaction/Registry.zig':registry,'protocol.zig':protocol.replace('@import("facades.zig").Rect','@import("gfx").Rect'),'probe.zig':reference}.items():(root/name).write_text(source)
    aliases=[('telar-core','core.zig'),('model','model.zig'),('gfx','gfx.zig'),('telar-window','window.zig')];command=['zig','build-exe','-O','ReleaseSafe','-lc']
    for name,_ in aliases:command+=['--dep',name]
    command+=['-Mroot='+str(root/'probe.zig'),'--dep','telar-core','-Mmodel='+str(root/'model.zig')]
    command+=['-M'+name+'='+str(root/file) for name,file in aliases if name!='model'];command+=['-femit-bin='+str(out/'reference')]
    candidate=[a.compiler,'-std=c++23','-O2','-ffp-contract=off','-Wall','-Wextra','-Werror','-I'+str(service),'-I'+str(repo/'dlls/telar-client/include'), '-I'+str(repo/'dlls/telar-base/include'), '-I'+str(repo/'dlls/telar-lua/include'), '-I'+str(repo/'dlls/telar-platform/include'), '-I'+str(repo/'dlls/telar-plugins/include'), '-I'+str(repo/'dlls/telar-config/include'),str(service/'tools/tab_drag_probe.cpp'),'-o',str(out/'candidate')]
    if a.sanitizers:candidate+=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
    for name,command in [('reference',command),('candidate',candidate)]:
        r=subprocess.run(command,capture_output=True);(out/(name+'-build.log')).write_bytes(r.stdout+r.stderr);(out/(name+'-build.json')).write_text(json.dumps(dict(command=command,actual_exit=r.returncode),indent=2)+'\n');r.check_returncode()
    programs=list(cases());payload=b''.join(operation for _,operations in programs for operation in operations);count=sum(len(operations) for _,operations in programs);(out/'input.bin').write_bytes(payload);records=[]
    for name in ('reference','candidate'):
        r=subprocess.run([str(out/name)],input=payload,capture_output=True,timeout=120);(out/(name+'.bin')).write_bytes(r.stdout);(out/(name+'.stderr')).write_bytes(r.stderr);records.append(dict(name=name,actual_exit=r.returncode,binary_sha256=hashlib.sha256((out/name).read_bytes()).hexdigest()));r.check_returncode()
    expected=(out/'reference.bin').read_bytes();actual=(out/'candidate.bin').read_bytes();result=dict(passed=expected==actual,sequences=len(programs),operations=count,executions=records,input_sha256=hashlib.sha256(payload).hexdigest(),output_sha256=hashlib.sha256(actual).hexdigest(),unchanged_original_sha256={n:hashlib.sha256((repo/n).read_bytes()).hexdigest() for n in [*names.values(),'src/core/schema/types.zig']},scope='Unchanged original gesture and drop-slot procedures; narrow model/registry/core/window facades. Finite delivered points and valid enum inputs only; no Qt, dispatcher presentation or full-GUI claim.',sanitizers={n:os.environ.get(n) for n in ('ASAN_OPTIONS','UBSAN_OPTIONS','LSAN_OPTIONS')});(out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    assert len(expected)==count*73,(len(expected),count);assert result['passed'],next((i for i,(x,y) in enumerate(zip(expected,actual)) if x!=y),min(len(expected),len(actual)));print('Matched',len(programs),'sequences and',count,'original operations',flush=True)

if __name__=='__main__':main()
