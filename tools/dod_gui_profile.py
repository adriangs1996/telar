#!/usr/bin/env python3
"""Sample only the GUI launched by the owned frame workload, after warmup."""
import argparse
import json
from pathlib import Path
import signal
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    gui = args.output/'gui'
    command = [sys.executable,str(Path(__file__).with_name('gui_slot_probe.py')),str(args.binary),str(gui),
               '--workload','full','--seconds','30','--viewport','1600','1000','--workload-warmup','5']
    with (args.output/'driver.log').open('w') as log:
        driver = subprocess.Popen(command,stdout=log,stderr=log)
        try:
            deadline = time.monotonic()+15
            pid = None
            while pid is None and time.monotonic() < deadline:
                for row in subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines():
                    parts = row.strip().split(None,1)
                    if len(parts)==2 and parts[1].startswith(str(args.binary)+' gui ') and str(gui) in parts[1]:
                        pid = int(parts[0])
                if driver.poll() is not None:
                    raise RuntimeError('GUI driver exited before sampling')
                time.sleep(.25)
            if pid is None:
                raise RuntimeError('owned GUI did not launch')
            time.sleep(7)
            with (args.output/'sample.log').open('w') as sample:
                subprocess.run(['/usr/bin/sample',str(pid),'8','1','-file',str(args.output/'gui-sample.txt')],stdout=sample,stderr=sample,check=True,timeout=25)
            with (args.output/'vmmap.txt').open('w') as memory:
                subprocess.run(['vmmap','-summary',str(pid)],stdout=memory,stderr=memory,check=True,timeout=15)
            driver.wait(timeout=40)
            if driver.returncode:
                raise RuntimeError(f'GUI workload failed: {driver.returncode}')
            (args.output/'receipt.json').write_text(json.dumps(dict(status=0,pid=pid,command=command,sample_seconds=8,warmup_seconds=7),indent=2)+'\n')
        finally:
            if driver.poll() is None:
                driver.send_signal(signal.SIGINT)
                driver.wait(timeout=30)


if __name__ == '__main__':
    main()
