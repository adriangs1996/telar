"""Compare bounded proportional-text runs against the unchanged original Caption.draw."""
import argparse,hashlib,json,os,random,shutil,struct,subprocess
from pathlib import Path
from check_history_card import protocol
from check_text_fit import unicode_facade

reference=r'''
const std = @import("std");
const io = @import("protocol.zig");
const Caption = @import("Caption.zig");
const Canvas = @import("Canvas.zig");
pub fn main() !void {
    var canvas: Canvas = .{};
    while (io.operation() >= 0) {
        const label = try io.readText();
        defer std.heap.page_allocator.free(label);
        try (Caption{ .bounds = .{ .width = 1000000 }, .label = .{ .text = label } }).draw(&canvas);
        try io.writeText("");
    }
}
'''

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--build-dir',type=Path,required=True);p.add_argument('--compiler',default='clang++');p.add_argument('--sanitizers',action='store_true');a=p.parse_args()
    repo=Path(__file__).resolve().parents[3];service=repo/'services/gui-cpp';build=a.build_dir.resolve();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);root=out/'original';root.mkdir()
    names={'Caption.zig':'src/gui/widgets/Caption.zig',**{n:'lib/cellgrid/'+n for n in ('GraphemeIterator.zig','Cluster.zig','text.zig')}}
    for dest,src in names.items():shutil.copy2(repo/src,root/dest)
    (root/'protocol.zig').write_text(protocol.replace('@import("facades.zig").Rect', '@import("gfx").Rect'));(root/'probe.zig').write_text(reference)
    (root/'facades.zig').write_text('pub const Rect = struct { x:f32=0, y:f32=0, width:f32=0, height:f32=0 };\n')
    (root/'gfx.zig').write_text('pub const Rect = struct { x:f32=0, y:f32=0, width:f32=0, height:f32=0 };\n')
    (root/'Label.zig').write_text('text: []const u8,\n')
    (root/'Canvas.zig').write_text('const io = @import("protocol.zig");\nconst Rect = @import("gfx").Rect;\nconst Label = @import("Label.zig");\npub fn textAt(_: *@This(), _: Rect, label: Label) !f32 { try io.writeText(label.text); return 1; }\n')
    (root/'cellgrid.zig').write_text('pub const GraphemeIterator = @import("GraphemeIterator.zig");\n');(root/'unicode.zig').write_text(unicode_facade)
    cache=dict(line.split('=',1) for line in (build/'CMakeCache.txt').read_text().splitlines() if '=' in line and not line.startswith(('#','//')))
    library=cache['GHOSTTY_VT_LIBRARY:FILEPATH'];include=cache['GHOSTTY_VT_INCLUDE_DIR:PATH']
    commands={
      'reference':['zig','build-exe','-O','ReleaseSafe','-lc',library,'--dep','cellgrid','--dep','gfx','-Mroot='+str(root/'probe.zig'),'--dep','unicode','-Mcellgrid='+str(root/'cellgrid.zig'),'-Mgfx='+str(root/'gfx.zig'),'-Municode='+str(root/'unicode.zig'),'-femit-bin='+str(out/'reference')],
      'candidate':[a.compiler,'-std=c++23','-O2','-Wall','-Wextra','-Werror','-I'+str(service),'-I'+include,str(service/'tools/caption_runs_probe.cpp'),library,'-o',str(out/'candidate')]
    }
    if a.sanitizers:commands['candidate']+=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
    if os.uname().sysname=='Darwin':commands['candidate']+=['-framework','Foundation','-framework','CoreText','-framework','CoreGraphics']
    for name,command in commands.items():
      r=subprocess.run(command,capture_output=True);(out/(name+'-build.log')).write_bytes(r.stdout+r.stderr);(out/(name+'-build.json')).write_text(json.dumps(dict(command=command,actual_exit=r.returncode),indent=2)+'\n');r.check_returncode()
    labels=[b'',b'History fixture failure',('History AV kerning: '+'AVATARVA'*13).encode(),b' '*128,bytes(range(256)),b'\xf0\x9f',b'\xc0\x80',b'\xed\xa0\x80']
    for count in (1,15,16,29,30,31,63,64,65,127,128,1024):
      labels += [(s*count).encode() for s in ('a','AV','word ','é','中','👩🏽‍💻','a\u0301','\u0301','\r\n')]
    rng=random.Random(0x43415054494f4e);alphabet='AVWTo fi\t\n é中👩🏽\u200d💻\u0301\u0327'
    labels += [''.join(rng.choice(alphabet) for _ in range(rng.randrange(512))).encode() for _ in range(2048)]
    labels += [bytes(rng.randrange(256) for _ in range(rng.randrange(512))) for _ in range(512)]
    payload=b''.join(b'\1'+struct.pack('<H',len(s))+s for s in labels);(out/'input.bin').write_bytes(payload);executions=[]
    for name in commands:
      r=subprocess.run([str(out/name)],input=payload,capture_output=True,timeout=120);(out/(name+'.bin')).write_bytes(r.stdout);(out/(name+'.stderr')).write_bytes(r.stderr);executions.append(dict(name=name,actual_exit=r.returncode,binary_sha256=hashlib.sha256((out/name).read_bytes()).hexdigest()));r.check_returncode()
    expected=(out/'reference.bin').read_bytes();actual=(out/'candidate.bin').read_bytes();result=dict(passed=expected==actual,records=len(labels),executions=executions,input_sha256=hashlib.sha256(payload).hexdigest(),output_sha256=hashlib.sha256(actual).hexdigest(),unchanged_original_sha256={n:hashlib.sha256((repo/n).read_bytes()).hexdigest() for n in names.values()},sanitizers={n:os.environ.get(n) for n in ('ASAN_OPTIONS','UBSAN_OPTIONS','LSAN_OPTIONS')})
    (out/'results.json').write_text(json.dumps(result,indent=2)+'\n');assert result['passed'],next((i for i,(x,y) in enumerate(zip(expected,actual)) if x!=y),min(len(expected),len(actual)))
    print('Matched',len(labels),'original Caption.draw run sequences',flush=True)

if __name__=='__main__':main()
