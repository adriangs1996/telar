"""Conservative host-load qualification at benchmark boundaries, not a profiler."""

from contextlib import contextmanager
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time


COMPILER = re.compile(r'(?:clang(?:\+\+)?(?:-[\d.]+)?|cc1(?:plus)?|zig|ninja|cmake|gcc(?:-[\d.]+)?|g\+\+(?:-[\d.]+)?|cc|c\+\+)')
COMPILER_CPU_LIMIT = 10.0


class HostLoadRejected(RuntimeError):
    pass


def host_snapshot():
    environment = dict(os.environ, LC_ALL='C')
    uptime = subprocess.check_output(['uptime'], text=True, env=environment, timeout=5).strip()
    processes = subprocess.check_output(['ps', '-Ao', 'pid,pcpu,comm'], text=True, env=environment, timeout=5)
    load = os.getloadavg()
    if not uptime or len(load) != 3 or any(not math.isfinite(value) or value < 0 for value in load):
        raise ValueError('Invalid host load observation')
    if len(processes.strip().splitlines()) < 2:
        raise ValueError('Missing process observations')
    compilers = []
    for line in processes.splitlines()[1:]:
        if not line.strip():
            continue
        pid, cpu, command = line.split(None, 2)
        cpu = float(cpu)
        if int(pid) <= 0 or not math.isfinite(cpu) or cpu < 0:
            raise ValueError('Invalid process CPU observation')
        if cpu > COMPILER_CPU_LIMIT and COMPILER.fullmatch(Path(command).name):
            compilers.append(dict(pid=int(pid), cpu_percent=cpu, command=command))
    return dict(recorded_at=datetime.now(timezone.utc).isoformat(), monotonic_ns=time.monotonic_ns(),
                uptime=uptime, load=list(load), active_compilers=compilers, processes=processes)


class HostLoadGate:
    def __init__(self, path, limits=None):
        self.path = Path(path)
        if self.path.exists():
            raise FileExistsError(self.path)
        cores = os.cpu_count() or 1
        limits = list(limits) if limits is not None else [max(2, cores * .5), max(3, cores * .75)]
        if len(limits) != 2 or any(not math.isfinite(value) or value <= 0 for value in limits):
            raise ValueError('Host load limits must be two finite positive numbers')
        self.policy = dict(logical_cpus=cores, maximum_load_one_five_minutes=limits,
                           compiler_cpu_limit_percent=COMPILER_CPU_LIMIT,
                           scope='Boundary snapshots only. A pass does not exclude all transient interference or replace workload, focus and presentation checks.')
        self.report = dict(status='pending', eligible=False, started_runs=0, policy=self.policy, observations=[])
        self.rejected = False
        self._save()

    def _save(self):
        temporary = self.path.with_suffix(self.path.suffix + '.tmp')
        temporary.write_text(json.dumps(self.report, indent=2) + '\n')
        temporary.replace(self.path)

    def checkpoint(self, phase):
        if self.report['status'] == 'qualified':
            raise RuntimeError('The benchmark host series is already finished')
        if self.rejected:
            raise HostLoadRejected(f'Entire benchmark series remains invalid: {self.path}')
        try:
            observation = host_snapshot()
            one, five = self.policy['maximum_load_one_five_minutes']
            valid = observation['load'][0] <= one and observation['load'][1] <= five and not observation['active_compilers']
            observation.update(phase=phase, valid=valid)
        except (OSError, ValueError, AttributeError, subprocess.SubprocessError) as error:
            observation = dict(phase=phase, valid=False, error=f'{type(error).__name__}: {error}')
        self.report['observations'].append(observation)
        if not observation['valid']:
            self.rejected = True
            self.report.update(status='discarded' if self.report['started_runs'] else 'deferred', eligible=False)
        self._save()
        if self.rejected:
            raise HostLoadRejected(f'Host load unavailable or unsuitable at {phase}; entire benchmark series excluded: {self.path}')

    @contextmanager
    def run(self, label):
        self.checkpoint(f'before:{label}')
        self.report['started_runs'] += 1
        self._save()
        try:
            yield
        finally:
            self.checkpoint(f'after:{label}')

    def finish(self):
        self.checkpoint('after-series')
        if not self.report['started_runs']:
            raise ValueError('Cannot qualify an empty benchmark series')
        self.report.update(status='qualified', eligible=True)
        self._save()
