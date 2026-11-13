#!/usr/bin/env python3
"""Byte-exact differential cases against the frozen application StreamHandler."""
import argparse
import datetime
import hashlib
import sys
import json
import random
from pathlib import Path
from control_query_oracle import Probe, ROOT, GHOSTTY, NATIVE

ESC = b'\x1b'
CSI = ESC + b'['
ST = ESC + b'\\'
DCS = ESC + b'P'
OSC = ESC + b']'


def cases():
    for name, data in {
        'DA1': CSI+b'c', 'DECID': ESC+b'Z', 'DA3': CSI+b'=c',
        'DSR': CSI+b'5n', 'CPR': b'abc'+CSI+b'6n',
        'DECXCPR': CSI+b'3;6H'+CSI+b'?6n',
        'CPR-origin': CSI+b'3;17r'+CSI+b'?6h'+CSI+b'4;9H'+CSI+b'6n',
        'DECRQSS-plain': DCS+b'$qm'+ST,
        'DECRQSS-style': CSI+b'1;2;3;4:3;5;7;8;9;53;38:2::4:5:6;48:5:31m'+DCS+b'$qm'+ST,
        'DECRQSS-margins': CSI+b'3;19r'+DCS+b'$qr'+ST,
        'DECRQSS-horizontal': CSI+b'?69h'+CSI+b'7;69s'+DCS+b'$qs'+ST,
        'DECRQSS-unknown': DCS+b'$qz'+ST,
        'DECRQSS-too-long': DCS+b'$q123'+ST,
        'DECRQSS-with-params': DCS+b'123$qm'+ST,
        'DECRQSS-cancel': DCS+b'$qm\x18'+CSI+b'6n',
        'DECRQSS-interrupt': DCS+b'$qm'+CSI+b'6n',
        'size-subscription': CSI+b'?2048h'+CSI+b'?2048l',
        'scheme-subscription': CSI+b'?2031h'+CSI+b'?2031l',
        'paste-events-subscription': CSI+b'?5522h'+CSI+b'?5522$p'+CSI+b'?5522l'+CSI+b'?5522$p',
        'paste-events-reset': CSI+b'?5522h'+ESC+b'c'+CSI+b'?5522$p',
        'keyboard': CSI+b'>7u'+CSI+b'?u'+CSI+b'<u'+CSI+b'?u',
        'colors': OSC+b'4;0;?;1;?;255;?'+ST,
        'colors-mutation': OSC+b'4;1;#123456;1;?'+ST,
        'dynamic-colors': OSC+b'10;?;?;?;?'+ST,
        'dynamic-mutation': OSC+b'10;#123456;#abcdef;#fedcba'+ST+OSC+b'10;?;?;?'+ST,
        'color-bell': OSC+b'4;1;?\a',
        'kitty-colors': OSC+b'21;foreground=?;background=?;cursor=?;0=?;255=?'+ST,
        'kitty-colors-set': OSC+b'21;foreground=#123456;foreground=?'+ST,
        'kitty-colors-unknown': OSC+b'21;selection_foreground=?;notakey=?'+ST,
        'clipboard-no-client': OSC+b'52;c;?'+ST,
        'title-default-denied': OSC+b'2;test title'+ST+CSI+b'21t',
        'checksum-default-denied': CSI+b'1;1;1;1;24;80*y',
        'enquiry-default': b'\x05',
        'unknown-commands': CSI+b'98765n'+DCS+b'+qXXXX;ABCD'+ST,
        'reset-style': CSI+b'31m'+ESC+b'c'+DCS+b'$qm'+ST,
        'alt-screen': b'hello'+CSI+b'?1049h'+b'x'+CSI+b'6n'+CSI+b'?1049l'+CSI+b'6n',
    }.items():
        yield name, data
    for control in range(32):
        if control in [7, 24, 26, 27]:
            continue
        byte = bytes([control])
        yield 'OSC-ignored-C0-'+byte.hex(), OSC+b'1'+byte+b'0;?'+ST
        yield 'DCS-ignored-C0-'+byte.hex(), DCS+b'$'+byte+b'qm'+ST
        yield 'termcap-ignored-C0-'+byte.hex(), DCS+b'+'+byte+b'q436F'+ST
    yield 'CSI-ignored-DEL', CSI+b'5\x7fn'
    yield 'ESC-ignored-DEL', ESC+b'\x7fZ'
    for count in [525, 526, 527, 528, 529]:
        for suffix in [b'', b';unknown=?', b';foreground=nonsense', b';']:
            data = OSC+b'21;foreground=#123456;'+b';'.join([b'foreground=?']*(count-1))+suffix+ST+OSC+b'10;?'+ST
            yield 'kitty-key-limit-'+str(count)+'-'+suffix.hex(), data
    for invalid in [b'no-such-color', b'#ggg', b'rgbi:2/0/0']:
        yield 'kitty-invalid-key-count-'+invalid.hex(), OSC+b'21;'+(b'foreground='+invalid+b';')*530+b'foreground=?'+ST
    for count in [525, 526, 527, 528, 529]:
        for suffix in [b'', b';unknown=?', b';']:
            yield 'kitty-short-key-limit-'+str(count)+'-'+suffix.hex(), OSC+b'21;foreground=#123456;'+b';'.join([b'0']*(count-1))+suffix+ST+OSC+b'10;?'+ST
    yield 'kitty-short-invalid-key-count', OSC+b'21;'+b'0;'*280+b'0=x;'*250+b'foreground=?'+ST
    for prefix in [ESC, CSI, DCS, DCS+b'+', ESC+b'_']:
        for c1 in range(0x80, 0xa0):
            if c1 in [0x90, 0x98, 0x9e, 0x9f]:
                tail = b'ignored'+ST
            elif c1 == 0x9b:
                tail = b'5n'
            elif c1 == 0x9d:
                tail = b'10;?'+ST
            else:
                tail = b''
            yield 'C1-in-control-'+prefix.hex()+'-'+hex(c1), prefix+bytes([c1])+tail+CSI+b'6n'
    for operation in [b'04', b'010', b'021', b'052', b'05522']:
        yield 'OSC-leading-zero-'+operation.decode(), OSC+operation+b';1;?'+ST
    randomizer = random.Random(0x435155455259)
    seeds = [CSI+b'5n', CSI+b'?6n', CSI+b'?2004$p', DCS+b'$qm'+ST, DCS+b'+q436F'+ST, OSC+b'4;1;?'+ST, ESC+b'_Ga=q,i=9,s=1,v=1;AAAAAA=='+ST, ESC+b'_25a1;q;cp=41'+ST]
    for index in range(1000):
        data = bytearray(randomizer.choice(seeds))
        position = randomizer.randrange(len(data)+1)
        mutation = bytes([randomizer.randrange(256)])
        if position == len(data) or randomizer.randrange(2):
            data[position:position] = mutation
        else:
            data[position:position+1] = mutation
        yield 'mutated-control-'+str(index), bytes(data)+CSI+b'6n'
    for mode in [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,25,40,45,47,66,67,69,117,1000,1002,1003,1004,1005,1006,1007,1015,1016,1035,1036,1039,1045,1047,1048,1049,2004,2026,2027,2031,2033,2048,5522,32768,65535,999999999]:
        for prefix in [b'',b'?']:
            yield f'mode-{prefix.decode()}-{mode}', CSI+prefix+str(mode).encode()+b'$p'
    for shape in range(7):
        yield f'cursor-style-{shape}', CSI+str(shape).encode()+b' q'+DCS+b'$q q'+ST
    for size in [14,16,18,19]:
        yield f'size-{size}', CSI+str(size).encode()+b't'
    for prefix in [b'\xc2', b'\xe0\xa0', b'\xf0\x9f\x92', b'\x80', b'\xff', b'\xc2\x05', b'\xe2\x82', b'\xc2\x18']:
        for name, query in [('CPR',CSI+b'6n'),('DSR',CSI+b'5n'),('DCS',DCS+b'$qm'+ST),('OSC',OSC+b'10;?'+ST)]:
            yield 'UTF8-boundary-'+prefix.hex()+'-'+name, prefix+query+b'a'+CSI+b'6n'
    for c1 in [b'\x9b6n', b'\x9052446d\x9c', b'\x9d10;?\x9c']:
        yield 'C1-ground-'+c1.hex(), c1+CSI+b'6n'
    for header in [b'a=113,i=9,s=1,v=1', b'a=q,i=9,s=1,v=1', b'a=q,i=9,s=1,v=1,f=24', b'a=q,i=9,f=100', b'a=q,i=9,f=97', b'a=q,i=9', b'a=q', b'a=q,I=9', b'a=q,i=9,I=10,p=3', b'a=q,i=9,s=1,v=1,p=3', b'a=q,i=9,s=1,v=1,q=1', b'a=q,i=9,s=1,v=1,q=2', b'a=q,i=9,s=0,v=1', b'a=q,i=9,s=32769,v=1', b'a=q,i=9,s=1,v=1,o=z', b'a=t,a=q,i=9,s=1,v=1', b'a=q,i=1,i=9,s=1,v=1', b'a=q,hello=world,i=9,s=1,v=1']:
        for payload in [b'', b'AAAAAA==', b'AAAA', b'%%%bad%%%']:
            yield 'graphics-'+header.decode()+'-'+payload.decode(), ESC+b'_G'+header+b';'+payload+ST
    for payload in [b'AAAAAA', b'AAAAA', b'A', b'AQI', b'AQID', b'AAAAAA==\n', b'AA=A', b'AAAA====', b'A A A A', b'AA==', b'AAA=', b'AB==', b'AAB=', b'____', b'----']:
        yield 'graphics-base64-'+payload.hex(), ESC+b'_Ga=q,i=9,s=1,v=1;'+payload+ST
    for family, data in [('DCS', DCS+b'$qm'), ('OSC', OSC+b'10;?'), ('APC', ESC+b'_Ga=q,i=9,s=1,v=1;AAAAAA==')]:
        for ending in [b'\x18', b'\x1a', ST]:
            yield 'cancel-'+family+'-'+ending.hex(), data+ending+CSI+b'5n'
    for control in [b'\x00', b'\x05', b'\x07', b'\x7f', b'\x80', b'\x9c']:
        yield 'DCS-control-'+control.hex(), DCS+b'$q'+control+b'm'+ST+CSI+b'5n'
    for codepoint in [b'41', b'E0A0', b'0x0041', b'+0041', b'1_0', b'', b'200000', b'zz', b'41;cp=42']:
        yield 'glyph-coverage-'+codepoint.decode(), ESC+b'_25a1;q;cp='+codepoint+ST
    rows=json.loads((ROOT/'measurements/control-queries/ghostty-termcap.json').read_text())['capabilities']
    for row in rows:
        if row['name']=='TN':
            continue  # Independent Telar identity assertion below.
        for key in [row['name'].encode().hex().upper().encode(),row['name'].encode().hex().lower().encode()]:
            yield 'termcap-'+row['name']+'-'+key.decode(),DCS+b'+q'+key+ST


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--native',type=Path,default=NATIVE)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--all-splits',action='store_true')
    args=parser.parse_args()
    failed=[]; checked=0
    for name,data in cases():
        reference=Probe(GHOSTTY)
        try:
            expected=reference.run(data)
        finally:
            reference.close()
        splits = range(len(data)+1) if len(data) <= 1024 else [0, 1, len(data)//2, len(data)-1, len(data)]
        for split in splits if args.all_splits else [None]:
            candidate=Probe(args.native)
            error = None
            try:
                actual=candidate.run(data,split)
            except (AssertionError, RuntimeError) as failure:
                actual = getattr(failure, 'reply', b'')
                error = str(failure)
            finally:
                candidate.close()
            checked+=1
            if actual!=expected or error:
                failed.append({'case':name,'split':split,'input':data.hex(),'expected':expected.hex(),'actual':actual.hex(),'error':error})
                break
    opt_in = [
        ('checksum-ascii', b'Hello, world!'+CSI+b'7;1;1;1;2;20*y'),
        ('checksum-unicode', 'Á界é𝄞'.encode()+CSI+b'7;1;1;1;2;20*y'),
        ('checksum-styles', CSI+b'1;2;3;4;5;7;8;9m'+b'a b'+CSI+b'7;1;1;1;2;20*y'),
        ('checksum-origin', CSI+b'3;19r'+CSI+b'?69h'+CSI+b'4;71s'+CSI+b'?6h'+b'hello'+CSI+b'7;1;1;1;2;20*y'),
        ('checksum-empty', CSI+b'7;1;12;12;1;1*y'),
        ('checksum-defaults', CSI+b'*y'),
        ('checksum-style-runs', b'A'+CSI+b'1;2;3m'+b'B'+CSI+b'0m'+b'C'+CSI+b'1;2;3m'+b'D'+CSI+b'7;1;1;1;2;80*y'),
        ('checksum-protected', CSI+b'1\"q'+b'A'+CSI+b'0\"q'+b'B'+CSI+b'7;1;1;1;2;80*y'),
        ('checksum-background-only', CSI+b'41m'+CSI+b'2J'+CSI+b'7;1;1;1;2;80*y'),
        ('checksum-wide-wrap', CSI+b'1;80H'+'界'.encode()+CSI+b'7;1;1;1;2;80*y'),
        ('checksum-many-graphemes', ('A'+'\u0301'*24).encode()+CSI+b'7;1;1;1;2;80*y'),
        ('checksum-scrolled-pages', b'row\r\n'*280+b'last'+CSI+b'7;1;1;1;24;80*y'),
        ('checksum-alt-roundtrip', b'primary'+CSI+b'?1049h'+b'alt'+CSI+b'7;1;1;1;24;80*y'+CSI+b'?1049l'+CSI+b'8;1;1;1;24;80*y'),
    ]
    for checksum_flags in range(32):
        for name, data in opt_in:
            data = CSI+str(checksum_flags).encode()+b'#y'+data
            reference = Probe(GHOSTTY)
            try:
                reference.policy(2)
                expected = reference.run(data)
            finally:
                reference.close()
            splits = range(len(data)+1) if len(data) <= 1024 else [0, 1, len(data)//2, len(data)-1, len(data)]
            for split in splits if args.all_splits else [None]:
                candidate = Probe(args.native)
                try:
                    candidate.policy(2)
                    actual = candidate.run(data, split)
                finally:
                    candidate.close()
                checked += 1
                if actual != expected:
                    failed.append({'case':f'{name}-{checksum_flags}','split':split,'input':data.hex(),'expected':expected.hex(),'actual':actual.hex()})
                    break
    for flags in [0, 4, 8, 16]:
        for name, data in [('DA-policy', CSI+b'c'), ('color-policy', OSC+b'10;?;?;?'+ST), ('ENQ-policy', b'\x05')]:
            reference = Probe(GHOSTTY)
            candidate = Probe(args.native)
            try:
                reference.policy(flags, b'answer')
                candidate.policy(flags, b'answer')
                expected = reference.run(data)
                actual = candidate.run(data)
            finally:
                reference.close()
                candidate.close()
            checked += 1
            if actual != expected:
                failed.append({'case':f'{name}-{flags}','expected':expected.hex(),'actual':actual.hex()})
    # Identity is intentionally distinct from Ghostty and verified independently.
    candidate=Probe(args.native)
    try:
        assert candidate.run(DCS+b'+q544e'+ST)==DCS+b'1+r544E=787465726D2D323536636F6C6F72'+ST
        assert candidate.run(CSI+b'>q')==DCS+b'>|telar dev'+ST
        assert candidate.run(CSI+b'>c')==CSI+b'>1;0;0c'
        assert candidate.run(CSI+b'?1004h'+CSI+b'?1004l') == CSI+b'O'
        assert candidate.run(CSI+b'?2033h'+CSI+b'?2033l') == CSI+b'?999;2n'
        # More than 64 admitted replies must drain without losses or duplicates.
        assert candidate.run(DCS+b'+q'+b';'.join([b'544E']*1000)+ST)==(DCS+b'1+r544E=787465726D2D323536636F6C6F72'+ST)*1000
        assert candidate.run((CSI+b'5n')*1000)==(CSI+b'0n')*1000
    finally:
        candidate.close()
    report={'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'command':sys.argv,'library_sha256':{str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in [args.native,GHOSTTY]},'script_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'checked':checked,'failures':failed,'scope':'Partial inventory; desktop, clipboard, graphics and subscriptions remain separate acceptance gates.'}
    if args.output:
        args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'checked':checked,'failed':len(failed),'cases':[f['case'] for f in failed]}))
    return bool(failed)

if __name__=='__main__':
    raise SystemExit(main())
