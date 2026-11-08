#!/usr/bin/env python3
"""Alternating before/after startup samples for one Claude hook event and IPC."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
from check_hook_cli import run_case


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--scratch',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    args.scratch.mkdir(parents=True,exist_ok=True)
    fixture={'provider':'claude','input':{'hook_event_name':'SessionStart','session_title':'Fixture','cwd':str(args.scratch)}}
    report={'scope':'one hook claude event, process startup, mapping and fixture IPC; no runtime or GUI; seven alternating pairs','platform':platform.platform(),'architecture':platform.machine(),'load':os.getloadavg(),'binaries':{},'pairs':[]}
    for name in ('baseline','candidate'):
        binary=getattr(args,name).resolve()
        report['binaries'][name]={'path':str(binary),'sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
        run_case(binary,args.scratch,fixture)
    digest=None
    for pair in range(7):
        measurements={}
        for name in (('baseline','candidate') if pair%2==0 else ('candidate','baseline')):
            samples=[]
            for _ in range(11):
                result,elapsed=run_case(getattr(args,name).resolve(),args.scratch,fixture)
                assert result['status']==0 and result['frames'], result
                current=hashlib.sha256(json.dumps(result,sort_keys=True).encode()).hexdigest()
                if digest is not None:assert current==digest
                digest=current
                samples.append(elapsed)
            measurements[name]={'samples_ns':samples,'p50_ns':statistics.median(samples)}
        measurements['p50_ratio']=measurements['candidate']['p50_ns']/measurements['baseline']['p50_ns']
        report['pairs'].append(measurements)
    report['p50_ns']={name:statistics.median([sample for pair in report['pairs'] for sample in pair[name]['samples_ns']]) for name in ('baseline','candidate')}
    report['median_paired_ratio']=statistics.median(pair['p50_ratio'] for pair in report['pairs'])
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({key:report[key] for key in ('p50_ns','median_paired_ratio')}))


if __name__=='__main__':
    main()
