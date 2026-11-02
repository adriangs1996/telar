import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import re
import struct
import subprocess


protocol = r'''
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime T: type) !T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    for (&bytes) |*byte| {
        const value = getchar();
        if (value < 0) {
            return error.TruncatedInput;
        }

        byte.* = @intCast(value);
    }

    return @bitCast(bytes);
}
fn writeText(text: []const u8) !void {
    const size: u32 = @intCast(text.len);
    for (std.mem.asBytes(&size)) |byte| {
        if (putchar(byte) < 0) {
            return error.WriteFailed;
        }
    }

    for (text) |byte| {
        if (putchar(byte) < 0) {
            return error.WriteFailed;
        }
    }
}
fn readText(storage: []u8) ![]const u8 {
    const size = try read(u32);
    if (size > storage.len) {
        return error.TextTooLong;
    }

    for (storage[0..size]) |*byte| {
        byte.* = try read(u8);
    }

    return storage[0..size];
}
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def method(source, name):
    start = source.index('pub fn ' + name + '(')
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def fixtures():
    cases = []
    branches = ['', 'worktree-', 'worktree/', 'worktree-task', 'worktree/task', 'worktree--task', 'plain/task', 'worktree-' + 'x' * 191, 'x' * 200, 'worktree/' + 'é' * 95]
    names = ['', 'Agent', 'Claude Code', 'x' * 31, 'x' * 32, '中' * 10, '🧪' * 8]
    for status in range(6):
        for task in [False, True]:
            for branch in branches:
                for name in names:
                    for total in [0, 1, 10, 65535]:
                        index = len(cases)
                        cases.append(dict(task=task, status=status, done=total // 2, total=total, name=name, step=['', 'x' * 96, 'é' * 48][index % 3], detail=['', 'event', 'z' * 96][index % 3], branch=branch, title=['', 'A task', 't' * 96][index % 3]))
    randomizer = random.Random(0x50454B4C)
    for _ in range(4096):
        def text(limit):
            value = ''.join(randomizer.choices(['a', ' ', 'é', '中', '🧪', '/', '-', '"'], k=randomizer.randrange(limit + 1)))
            return value.encode()[:limit].decode(errors='ignore')
        total = randomizer.choice([0, 1, 9, 10, 99, 100, 999, 1000, 65535])
        cases.append(dict(task=bool(randomizer.getrandbits(1)), status=randomizer.randrange(6), done=randomizer.randrange(total + 1), total=total, name=text(32), step=text(96), detail=text(96), branch=text(200), title=text(96)))
    return cases


def parse(data, count):
    results = []
    offset = 0
    for _ in range(count):
        row = []
        for _ in range(2):
            size = struct.unpack_from('<I', data, offset)[0]
            offset += 4
            row.append(data[offset:offset + size])
            offset += size
        results.append(row)
    assert offset == len(data)
    return results


def main():
    parser = argparse.ArgumentParser(description='Compare peek task titles and bounded facts against unchanged original Zig bodies')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    originals = ['src/gui/widgets/overlays/PeekModal.zig', 'src/model/agents/Agent.zig', 'src/model/workspace/WorktreeRow.zig', 'src/core/schema/types.zig', 'src/core/agent_manifest.zig']
    modal, agent_source, task_source, _types, manifest = [(repository / name).read_text() for name in originals]
    for name in originals:
        (output / Path(name).name).write_bytes((repository / name).read_bytes())
    facts = modal[modal.index('    var facts_buffer:'):modal.index('    try canvas.text(content.row(0)')]
    title = re.search(r'^\s*\.title = (.*),$', modal, re.M).group(1)
    generic = re.search(r'^pub const generic_display_name[^=]*= (.*);$', manifest, re.M).group(1)
    facade = 'const std = @import("std");\nconst core = struct { const generic_display_name = ' + generic + '; };\n'
    facade += 'const Status = enum(u8) { unknown, working, blocked, ready, failed, done };\n'
    facade += 'const Agent = struct { display_name: []const u8, display_name_len: usize, status: Status, plan_done: u16, plan_total: u16, plan_step: []const u8, plan_step_len: usize, last_event: []const u8, last_event_len: usize,\n'
    facade += '\n'.join(method(agent_source, name) for name in ['displayName', 'planStep', 'lastEvent']) + '\n};\n'
    facade += 'const WorktreeRow = struct { branch: []const u8, branch_len: usize, title: []const u8, title_len: usize,\n'
    facade += '\n'.join(method(task_source, name) for name in ['branchSlice', 'titleSlice', 'displayName', 'handle']) + '\n};\n'
    main_body = r'''
pub fn main() !void {
    while (getchar() >= 0) {
        const has_task = try read(u8) != 0;
        const status: Status = @enumFromInt(try read(u8));
        const done = try read(u16);
        const total = try read(u16);
        var name_storage: [512]u8 = undefined;
        var step_storage: [512]u8 = undefined;
        var detail_storage: [512]u8 = undefined;
        var branch_storage: [512]u8 = undefined;
        var title_storage: [512]u8 = undefined;
        const name = try readText(&name_storage);
        const step = try readText(&step_storage);
        const detail = try readText(&detail_storage);
        const branch = try readText(&branch_storage);
        const task_title = try readText(&title_storage);
        const value: Agent = .{ .display_name = name, .display_name_len = name.len, .status = status, .plan_done = done, .plan_total = total, .plan_step = step, .plan_step_len = step.len, .last_event = detail, .last_event_len = detail.len };
        const task_value: WorktreeRow = .{ .branch = branch, .branch_len = branch.len, .title = task_title, .title_len = task_title.len };
        const agent = &value;
        const task: ?*const WorktreeRow = if (has_task) &task_value else null;
        try writeText(TITLE);
FACTS
        try writeText(facts.buffered());
    }
}
'''
    (output / 'probe.zig').write_text(facade + protocol + main_body.replace('TITLE', title).replace('FACTS', facts))
    build = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', str(output / 'probe.zig'), '-femit-bin=' + str(output / 'original-peek-labels')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(build, cwd=repository, stdout=log, stderr=subprocess.STDOUT, check=True)
    cases = fixtures()
    (output / 'fixtures.json').write_text(json.dumps(cases, ensure_ascii=False, indent=2) + '\n')
    requests = bytearray()
    for case in cases:
        requests.extend(b'\0' + struct.pack('<BBHH', case['task'], case['status'], case['done'], case['total']))
        for key in ['name', 'step', 'detail', 'branch', 'title']:
            data = case[key].encode()
            requests.extend(struct.pack('<I', len(data)) + data)
    (output / 'requests.bin').write_bytes(requests)
    outputs = {}
    binary = options.build_dir.resolve() / 'gui-peek-labels-probe'
    for kind, executable in [('original', output / 'original-peek-labels'), ('cpp', binary)]:
        result = subprocess.run([str(executable)], input=requests, capture_output=True, check=True)
        (output / (kind + '.bin')).write_bytes(result.stdout)
        (output / (kind + '.stderr')).write_bytes(result.stderr)
        outputs[kind] = result.stdout
    left, right = [parse(outputs[kind], len(cases)) for kind in ['original', 'cpp']]
    differences = [dict(index=index, case=cases[index], original=[item.hex() for item in original], cpp=[item.hex() for item in cpp]) for index, (original, cpp) in enumerate(zip(left, right)) if original != cpp]
    (output / 'differences.json').write_text(json.dumps(differences, ensure_ascii=False, indent=2) + '\n')
    sources = originals + ['services/gui-cpp/presentation/peek_labels.hpp', 'services/gui-cpp/presentation/agent_card_labels.hpp', 'services/gui-cpp/application/records.hpp', 'services/gui-cpp/tools/peek_labels_probe.cpp', 'services/gui-cpp/tools/check_peek_labels.py']
    record = dict(recorded_at=datetime.now(timezone.utc).isoformat(), command=build, cases=len(cases), different_cases=len(differences), input_bytes=len(requests), input_sha256=sha(requests), output_bytes={kind:len(data) for kind,data in outputs.items()}, output_sha256={kind:sha(data) for kind,data in outputs.items()}, source_sha256={name:sha((repository / name).read_bytes()) for name in sources}, binary_sha256=sha(binary.read_bytes()), sanitizer_environment={key:os.environ.get(key) for key in ['ASAN_OPTIONS', 'UBSAN_OPTIONS', 'LSAN_OPTIONS']}, scope='Unchanged original PeekModal facts body/title expression and exact Agent/WorktreeRow label methods, with a minimal field-only facade. This does not qualify runtime projection, native task/plan rendering or complete visual/performance parity.')
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
    assert not differences, f'{len(differences)} peek title/facts differences retained'


if __name__ == '__main__':
    main()
