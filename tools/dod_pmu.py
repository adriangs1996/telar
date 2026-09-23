#!/usr/bin/env python3
"""Copy the installed Xcode CPU template and select a mode present in its registry.

The original template is never modified. Exported schemas and events decide
whether a capture is usable; the selected mode name alone is not evidence.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--mode', choices=['processing','l1d_miss_sampling'], required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    developer = Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
    contents = developer.parent
    source = contents/'Applications/Instruments.app/Contents/Resources/templates/CPU Counters.tracetemplate'
    registry = contents/'SharedFrameworks/RecountDT.framework/Versions/A/Resources/Analysis/bottleneck.json'
    configuration = json.loads(registry.read_text())
    mode = next(row for row in configuration['modes'] if row['name']==args.mode)
    archive = plistlib.loads(source.read_bytes())
    changed = 0
    for index, value in enumerate(archive['$objects']):
        if not isinstance(value, bytes) or b'selectedCountingMode' not in value:
            continue
        options = json.loads(value)
        options['selectedCountingMode'] = dict(analysisMode='bottleneck',countingMode=args.mode)
        options['selectedCountingModeDisplayName'] = mode['display_name']
        archive['$objects'][index] = json.dumps(options).encode()
        changed += 1
    if changed != 1:
        raise RuntimeError(f'unsupported template structure: {changed} recording configurations')
    template = args.output/'CPU.tracetemplate'
    template.write_bytes(plistlib.dumps(archive,fmt=plistlib.FMT_BINARY))
    manifest = dict(mode=args.mode,binary=str(args.binary.resolve()),
                    binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                    original_template=str(source),original_template_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                    template_sha256=hashlib.sha256(template.read_bytes()).hexdigest(),
                    registry=str(registry),registry_sha256=hashlib.sha256(registry.read_bytes()).hexdigest(),
                    expected_metrics=[row['display_name'] for row in mode['metrics']])
    (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    trace = args.output/'capture.trace'
    command = ['xcrun','xctrace','record','--template',str(template),'--time-limit','10s',
               '--output',str(trace),'--target-stdout',str(args.output/'workloads.jsonl'),'--launch','--',str(args.binary)]
    with (args.output/'record.log').open('w') as log:
        subprocess.run(command,stdout=log,stderr=log,check=True,timeout=90)
    with (args.output/'toc.xml').open('w') as out:
        subprocess.run(['xcrun','xctrace','export','--input',str(trace),'--toc'],stdout=out,check=True,timeout=30)
    tables = {row.get('schema') for row in ET.parse(args.output/'toc.xml').findall('.//table')}
    for schema in ['MetricTable','CountingModeSamples'] + (['SamplingModeSamples'] if args.mode == 'l1d_miss_sampling' else []):
        if schema not in tables:
            raise RuntimeError(f'missing exported table {schema}')
        with (args.output/f'{schema}.xml').open('w') as out:
            subprocess.run(['xcrun','xctrace','export','--input',str(trace),'--xpath',
                            f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],stdout=out,check=True,timeout=30)
    print(args.mode, 'recorded and exported',flush=True)


if __name__ == '__main__':
    main()
