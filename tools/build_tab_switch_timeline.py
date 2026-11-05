#!/usr/bin/env python3
"""Build a diagnostic tab-switch probe with per-drawable commit/GPU clocks.

This adds observation work and is not the headline acceptance probe. The normal
probe remains in the output directory; timeline-probe.dylib is the diagnostic one.
All existing pixel, generation, phase and native-presentation gates are retained.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from build_tab_switch_probe import build


# Exact anchors deliberately reject an incompatible base observer.
TIMELINE_PATCHES = (
    (
        r'''    static unsigned last_seen_generations[16];
    static double switch_input_at[ProbeSampleCapacity], switch_presented_at[ProbeSampleCapacity];
    static BOOL layout_key(BOOL create);
static int count, limit;
''',
        r'''    static unsigned last_seen_generations[16];
    static double switch_input_at[ProbeSampleCapacity], switch_presented_at[ProbeSampleCapacity];
    static unsigned switch_commits[ProbeSampleCapacity];
    static double switch_committed[ProbeSampleCapacity], switch_gpu_started[ProbeSampleCapacity], switch_gpu_ended[ProbeSampleCapacity], switch_completed[ProbeSampleCapacity];
    static BOOL layout_key(BOOL create);
static int count, limit;
''',
    ),
    (
        r'''
@interface ProbeFrame : NSObject {
@public unsigned sequence, geometry, tab_index, content_generation; NSUInteger drawable_id; double gpu, work, presented; BOOL verified;
}
@end
''',
        r'''
@interface ProbeFrame : NSObject {
@public unsigned sequence, geometry, tab_index, content_generation; NSUInteger drawable_id; double gpu, work, presented, committed, gpu_started, gpu_ended; unsigned commits; BOOL verified;
}
@end
''',
    ),
    (
        r'''        [switch_samples addObject:@{@"target_tab": @(expected_tabs[i]), @"minimum_generation": @(minimum_generations[i]),
                @"observed_tab": @(observed_tabs[i]), @"observed_generation": @(observed_generations[i]),
                @"input_at": @(switch_input_at[i]), @"presented_at": @(switch_presented_at[i])}];
            [gpu addObject:@(gpu_samples[i])];
        [work addObject:@(gpu_work_samples[i])];
''',
        r'''        [switch_samples addObject:@{@"target_tab": @(expected_tabs[i]), @"minimum_generation": @(minimum_generations[i]),
                @"observed_tab": @(observed_tabs[i]), @"observed_generation": @(observed_generations[i]),
                @"input_at": @(switch_input_at[i]), @"presented_at": @(switch_presented_at[i]),
                @"commit_at": @(switch_committed[i]), @"commit_count": @(switch_commits[i]), @"gpu_started_at": @(switch_gpu_started[i]), @"gpu_ended_at": @(switch_gpu_ended[i]), @"completed_at": @(switch_completed[i])}];
            [gpu addObject:@(gpu_samples[i])];
        [work addObject:@(gpu_work_samples[i])];
''',
    ),
    (
        r'''        observed_generations[count] = frame->content_generation;
        last_seen_generations[frame->tab_index] = frame->content_generation;
        pending=NO;count++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(25+((uint32_t)(count*1103515245u+12345u)>>16)%50)*NSEC_PER_MSEC),dispatch_get_main_queue(),^{send_key();});
''',
        r'''        observed_generations[count] = frame->content_generation;
        last_seen_generations[frame->tab_index] = frame->content_generation;
        switch_committed[count] = frame->committed;
        switch_commits[count] = frame->commits;
        switch_gpu_started[count] = frame->gpu_started;
        switch_gpu_ended[count] = frame->gpu_ended;
        switch_completed[count] = frame->gpu;
        pending=NO;count++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(25+((uint32_t)(count*1103515245u+12345u)>>16)%50)*NSEC_PER_MSEC),dispatch_get_main_queue(),^{send_key();});
''',
    ),
    (
        r'''            double done = CACurrentMediaTime();
            if (completed.status == MTLCommandBufferStatusCompleted) {
                r->frame->work = (completed.GPUEndTime - completed.GPUStartTime) * 1000;
                verify_readback(r, done);
''',
        r'''            double done = CACurrentMediaTime();
            if (completed.status == MTLCommandBufferStatusCompleted) {
                r->frame->gpu_started = completed.GPUStartTime;
                r->frame->gpu_ended = completed.GPUEndTime;
                r->frame->work = (completed.GPUEndTime - completed.GPUStartTime) * 1000;
                verify_readback(r, done);
''',
    ),
    (
        r'''        }
    }
    ((void(*)(id,SEL))original_commit)(self,selector);
}
''',
        r'''        }
    }
    if (r) { r->frame->committed = CACurrentMediaTime(); ++r->frame->commits; }
    ((void(*)(id,SEL))original_commit)(self,selector);
}
''',
    ),
    (
        r'''            double done = CACurrentMediaTime();
            if (!feedback.error) {
                r->frame->work = (feedback.GPUEndTime - feedback.GPUStartTime) * 1000;
                verify_readback(r, done);
''',
        r'''            double done = CACurrentMediaTime();
            if (!feedback.error) {
                r->frame->gpu_started = feedback.GPUStartTime;
                r->frame->gpu_ended = feedback.GPUEndTime;
                r->frame->work = (feedback.GPUEndTime - feedback.GPUStartTime) * 1000;
                verify_readback(r, done);
''',
    ),
    (
        r'''            }
        }
    }
    ((void(*)(id,SEL,const id<MTL4CommandBuffer> *,NSUInteger,id))original_commit4)(self,selector,buffers,count,options);
''',
        r'''            }
        }
    }
    const double committed = CACurrentMediaTime();
    for (NSUInteger i = 0; i < count; i++) {
        ProbeReadback *r = objc_getAssociatedObject(buffers[i], &readback_key);
        if (r) { r->frame->committed = committed; ++r->frame->commits; }
    }
    ((void(*)(id,SEL,const id<MTL4CommandBuffer> *,NSUInteger,id))original_commit4)(self,selector,buffers,count,options);
''',
    ),
)


def add_timeline(contents):
    for old, new in TIMELINE_PATCHES:
        if contents.count(old) != 1:
            raise ValueError(f'Native timeline anchor changed: {old[:80]!r}')
        contents = contents.replace(old, new)
    return contents


def build_timeline(output):
    normal = build(output)
    directory = normal.parent
    source = directory / 'timeline.m'
    source.write_text(add_timeline((directory / 'gui_tui_latency.m').read_text()))
    library = directory / 'timeline-probe.dylib'
    command = ['clang', '-dynamiclib', '-O2', '-fobjc-arc', '-framework', 'AppKit',
               '-framework', 'QuartzCore', '-framework', 'Metal', str(source), '-o', str(library)]
    result = subprocess.run(command, capture_output=True, text=True)
    (directory / 'timeline-build.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    shutil.copy2(__file__, directory / Path(__file__).name)
    files = [source, library, directory / Path(__file__).name]
    (directory / 'timeline-build.json').write_text(json.dumps({
        'scope': 'Instrumented diagnostic only; no performance acceptance',
        'command': command,
        'sha256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in files},
    }, indent=2) + '\n')
    return library


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New private output directory')
    args = parser.parse_args()
    build_timeline(args.output)


if __name__ == '__main__':
    main()
