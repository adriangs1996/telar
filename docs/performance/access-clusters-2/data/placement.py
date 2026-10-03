"""Normalize instructions and verified read-only relocations, preserving immediates."""
from pathlib import Path
import re, struct, hashlib, json, sys
p=Path(sys.argv[1])
def image(side):
 data=(p/side/'bin/telar-benchmarks').read_bytes(); offset=32; segments=[]
 for _ in range(struct.unpack_from('<I',data,16)[0]):
  command,size=struct.unpack_from('<II',data,offset)
  if command==0x19:
   vmaddr,vmsize,fileoff,filesize=struct.unpack_from('<QQQQ',data,offset+24)
   segments.append((vmaddr,fileoff,filesize))
  offset+=size
 def read(address):
  for start,off,size in segments:
   if start<=address<start+size: return data[off+address-start:off+address-start+32]
  raise ValueError(hex(address))
 return read

def normalize(side, lines):
 read=image(side); result=[]; constants={}
 for line in lines:
  m=re.match(r'([0-9a-f]+):\s+(.*)',line)
  if not m: continue
  instruction=m[2]
  adrp=re.match(r'adrp\s+(x\d+), (0x[0-9a-f]+)',instruction)
  if adrp:
   constants[adrp[1]]=int(adrp[2],16)
   instruction=f'adrp {adrp[1]}, CONST_PAGE'
  else:
   operand=re.match(r'(add|ldr)\s+[^,]+, (?:\[)?(x\d+), #(0x[0-9a-f]+)',instruction)
   if operand and operand[2] in constants:
    address=constants.pop(operand[2])+int(operand[3],16)
    digest=hashlib.sha256(read(address)).hexdigest()
    instruction=instruction.replace(operand[3], 'CONST_'+digest)
   # A register write consumes a tracked page if not the expected add/load.
   written=re.match(r'\w+\s+(x\d+),',instruction)
   if written: constants.pop(written[1],None)
  instruction=re.sub(r'0x[0-9a-f]+ <([^>]+)>',lambda m:'<'+re.sub(r'\+0x[0-9a-f]+','',m[1])+'>',instruction)
  instruction=re.sub(r'__anon_\d+','__anon',instruction)
  result.append(instruction)
 return '\n'.join(result)+'\n'
result={}
for symbol in ['ClientEventContext.receiveFrame','ClientEventContext.finishEvent','ClientEventContext.summarizeMachine','machine-loop']:
 normalized=[]
 for side in ['A','C']:
  if symbol=='machine-loop':
   lines=(p/f'{side}-main.execute.s').read_text().splitlines()
   start=max(i for i,l in enumerate(lines) if '<_ClientEventContext.summarizeMachine>' in l)-5
   check=next(l for l in lines[start:] if '\tb.eq\t' in l)
   address=re.search(r'0x([0-9a-f]+)',check)[1]
   end=next(i for i,l in enumerate(lines) if l.startswith(address+':'))
   lines=lines[start:end]
  else: lines=(p/f'{side}-{symbol}.s').read_text().splitlines()
  s=normalize(side,lines);(p/f'{side}-{symbol}.normalized.s').write_text(s);normalized.append(s)
 result[symbol]=normalized[0]==normalized[1]
(p/'C-placement.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
