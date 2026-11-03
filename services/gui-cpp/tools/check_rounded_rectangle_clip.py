"""Compare rounded-paint clipping with the unchanged original Zig clipQuad."""
from pathlib import Path
import argparse,hashlib,json,os,random,shutil,struct,subprocess
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--zig',default=os.environ.get('ZIG','zig'));parser.add_argument('--compiler',default=os.environ.get('CXX','clang++'));parser.add_argument('--sanitize',action='store_true');options=parser.parse_args()
repo=Path(__file__).resolve().parents[3];base=repo/'services/gui-cpp';local=base/'tools';out=options.output.resolve();out.mkdir(parents=True,exist_ok=False);original=out/'original';original.mkdir();records=[]
def run(command,label,**kw):
 with (out/(label+'.log')).open('wb') as log:r=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,**kw)
 records.append(dict(command=command,actual_exit=r.returncode));(out/'commands.json').write_text(json.dumps(records,indent=2)+'\n');r.check_returncode()
identities={}
for name in ('Quad.zig','Rect.zig'):
 p=repo/'lib/gfx'/name;shutil.copy2(p,original/name);identities[str(p.relative_to(repo))]=hashlib.sha256(p.read_bytes()).hexdigest()
flow=repo/'lib/gfx/QuadList.zig';source=flow.read_text();start=source.index('fn clipQuad(');begin=source.index('{',start);depth=1;end=begin+1
while depth:
 depth+=(source[end]=='{')-(source[end]=='}');end+=1
body=source[start:end];identities[str(flow.relative_to(repo))]=hashlib.sha256(flow.read_bytes()).hexdigest();(original/'clip-original.txt').write_text(body+'\n')
protocol='''const std = @import("std");
const Rect = @import("Rect.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
pub fn operation() c_int { return getchar(); }
pub fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| {
        const value = getchar();
        if (value < 0) { return error.TruncatedInput; }
        byte.* = @intCast(value);
    }
    return @bitCast(bytes);
}
pub fn write(value: anytype) !void {
    for (std.mem.asBytes(&value)) |byte| {
        if (putchar(byte) < 0) { return error.WriteFailed; }
    }
}
pub fn readRect() !Rect {
    const x = try read(f32);
    const y = try read(f32);
    const width = try read(f32);
    return .{ .x=x, .y=y, .width=width, .height=try read(f32) };
}
'''
(original/'protocol.zig').write_text(protocol)
fields=('x','y','width','height','u0','v0','u1','v1','r','g','b','a','radius','border','texture','reserved','border_r','border_g','border_b','border_a');outputs=('x','y','width','height','r','g','b','a','radius','border','border_r','border_g','border_b','border_a')
driver='''const Quad = @import("Quad.zig").Quad;
const Rect = @import("Rect.zig");
const io = @import("protocol.zig");
'''+body+'''
pub fn main() !void {
    while (true) {
        const incoming = io.operation();
        if (incoming < 0) { return; }
        const quad: Quad = .{
'''+''.join('            .'+f+'=try io.read(f32),\n' for f in fields)+'''        };
        const result = clipQuad(quad,try io.readRect());
        const values = [_]f32{'''+','.join('result.'+f for f in outputs)+'''};
        for (values) |value| { try io.write(value); }
    }
}
'''
(original/'probe.zig').write_text(driver)
run([options.zig,'build-exe','-O','ReleaseSafe','-lc',str(original/'probe.zig'),'-femit-bin='+str(out/'reference')],'reference-build')
shutil.copy2(local/'rounded_rectangle_clip_probe.cpp',out/'rounded_rectangle_clip_probe.cpp')
(out/'graphics').mkdir();shutil.copy2(base/'graphics/rounded_rectangle.hpp',out/'graphics/rounded_rectangle.hpp')
command=[options.compiler,'-std=c++23','-O3','-ffp-contract=off','-Wall','-Wextra','-Werror','-I'+str(base),'-I'+str(base/'tools'),'-I'+str(repo/'services/runtime-cpp'),'-I'+str(repo/'dlls/telar-client/include'), '-I'+str(repo/'dlls/telar-base/include'), '-I'+str(repo/'dlls/telar-lua/include'), '-I'+str(repo/'dlls/telar-platform/include'), '-I'+str(repo/'dlls/telar-plugins/include'), '-I'+str(repo/'dlls/telar-config/include'),str(out/'rounded_rectangle_clip_probe.cpp'),'-o',str(out/'candidate')]
if options.sanitize:command[1:1]=['-g','-fno-omit-frame-pointer','-fsanitize=address,undefined']
run(command,'candidate-build')
rng=random.Random(0x5241494c);cases=[]
def add(bounds,clip,radius=3):
 quad=[*bounds,*([.5/1024]*4),.1,.2,.3,.22,radius,1,0,0,.9,.8,.7,.09];cases.append(b'\0'+struct.pack('<24f',*quad,*clip))
for x in (-0.0,0.0,-3,1,16.25,4096.5):
 for y in (-0.0,0.0,-3,1,16.25):
  for w,h in ((6,20),(0,20),(6,0),(0,0),(20,6),(1.5,2.75)):
   for clip in ((0,0,52,800),(-100,-100,1000,1000),(x,y,w,h),(x+3,y,w,h),(x,y+3,w,h),(x+w,y+h,1,1),(x-1,y-1,w+2,h+2),(0,-0.0,0,0),(-0.0,0,6,20),(-1,-1,-2,-3)):
    for radius in (0,1.5,3,10):add((x,y,w,h),clip,radius)
for _ in range(25000):
 bounds=tuple(rng.randrange(-32768,32768)/8 for _ in range(2))+tuple(rng.randrange(0,8192)/8 for _ in range(2));clip=tuple(rng.randrange(-32768,32768)/8 for _ in range(2))+tuple(rng.randrange(0,8192)/8 for _ in range(2));add(bounds,clip,rng.choice((0,1.5,3,7.25,999)))
payload=b''.join(cases);(out/'input.bin').write_bytes(payload);values={}
for variant in ('reference','candidate'):
 env=dict(os.environ,ASAN_OPTIONS='detect_leaks=1',UBSAN_OPTIONS='halt_on_error=1');env.pop('LSAN_OPTIONS',None)
 with (out/(variant+'-output.bin')).open('wb') as output,(out/(variant+'-stderr.log')).open('wb') as log:r=subprocess.run([str(out/variant)],input=payload,stdout=output,stderr=log,env=env,timeout=30)
 assert r.returncode==0,(variant,r.returncode);values[variant]=(out/(variant+'-output.bin')).read_bytes();assert len(values[variant])==len(cases)*56
left,right=values['reference'],values['candidate'];bad=[i for i in range(len(cases)) if left[i*56:(i+1)*56]!=right[i*56:(i+1)*56]]
result=dict(scope='Exact unchanged original clipQuad function and actual original Quad/Rect types, comparing all14 rounded-paint geometry/style fields. Protocol/driver adapters only; no GUI/performance acceptance.',records=len(cases),different_records=len(bad),first_differences=bad[:32],original_sha256=identities,extracted_function_sha256=hashlib.sha256(body.encode()).hexdigest(),input_sha256=hashlib.sha256(payload).hexdigest(),output_sha256={k:hashlib.sha256(v).hexdigest() for k,v in values.items()},sanitize=options.sanitize,architecture=os.uname().machine,paint_header_sha256=hashlib.sha256((out/'graphics/rounded_rectangle.hpp').read_bytes()).hexdigest())
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2));assert not bad
