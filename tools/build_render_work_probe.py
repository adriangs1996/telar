"""Build a private legacy-Metal work census around the ordinary typing probe."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

from build_thread_cpu_probe import copy_typing_probe


def build(output):
    directory = Path(output).resolve()
    source = Path(__file__).resolve().parent
    copy_typing_probe(directory, source)
    for name in ("render_work_census.h", "render_work_census.c"):
        shutil.copy2(source / name, directory / name)
    names = re.findall(r"^  (render_work_[a-z0-9_]+),?$", (source / "render_work_census.h").read_text(), re.M)
    if not names or names[-1] != "render_work_count":
        raise ValueError("Render counter enum changed")
    names.pop()
    path = directory / "gui_tui_latency.m"
    contents = '#include "render_work_census.h"\n' + path.read_text()

    def replace(before, after):
        nonlocal contents
        if contents.count(before) != 1:
            raise ValueError(f"Render census anchor changed: {before[:100]!r}")
        contents = contents.replace(before, after)

    counters = ",\n".join(f'            @"{name.removeprefix("render_work_")}": @(census_result.counts[{name}])' for name in names)
    helpers = '''
static atomic_uintptr_t census_layer_identity;
static RenderWorkSnapshot census_result;
static BOOL census_started;
_Static_assert(render_work_sequence_capacity == ProbeSampleCapacity + 1, "Sequence capacity differs from native probe");

static BOOL census_queue(id<MTLCommandQueue> queue) {
    uintptr_t identity = atomic_load_explicit(&target_queue_identity, memory_order_acquire);
    return identity && identity == (uintptr_t)(__bridge void *)queue;
}

static NSDictionary *census_json(void) {
    NSMutableArray *sequences = [NSMutableArray arrayWithCapacity:render_work_sequence_capacity];
    for (unsigned sequence = 0; sequence < render_work_sequence_capacity; ++sequence) {
        [sequences addObject:@(census_result.commits_by_sequence[sequence])];
    }
    return @{
        @"commits_by_sequence": sequences,
        @"sequence_attribution": @"Input epoch observed at commit entry; includes inter-input work and does not establish frame content or causality.",
        @"version": @1, @"complete": @(census_result.complete), @"errors": @(census_result.errors),
        @"clock": @"CLOCK_UPTIME_RAW", @"begin_ns": @(census_result.begin_ns), @"end_ns": @(census_result.end_ns),
        @"queue_identity": @(atomic_load(&target_queue_identity)), @"layer_identity": @(atomic_load(&census_layer_identity)),
        @"scope": @"Hook observations within measured boundaries; marker-qualified queue and layer. Legacy Metal only. Source counters require privately instrumented GUI. Not timing or exact per-frame GPU work.",
        @"counts": @{
COUNTERS
        },
    };
}
'''.replace("COUNTERS", counters)
    replace("@interface ProbeFrame : NSObject {", helpers + "\n@interface ProbeFrame : NSObject {")
    replace("@public unsigned sequence, geometry; NSUInteger drawable_id;", "@public unsigned sequence, geometry; uintptr_t census_layer; NSUInteger drawable_id;")
    replace("        getrusage(RUSAGE_SELF, &measurement_start_usage);", '''        if (!atomic_load(&target_queue_identity) || !atomic_load(&census_layer_identity) || telar_render_work_begin() != 0) {
            _exit(75);
        }
        census_started = YES;
        getrusage(RUSAGE_SELF, &measurement_start_usage);''')
    replace("    finished=YES;", '''    if (census_started) {
        census_result = telar_render_work_end();
        census_started = NO;
    }
    finished=YES;''')
    replace("    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];", '    result[@"render_work_census"] = census_json();\n    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];')
    replace("    initial_presentation = (ProbeInitialPresentation){\n", "    atomic_store(&census_layer_identity, frame->census_layer);\n    initial_presentation = (ProbeInitialPresentation){\n")
    replace("    id drawable = ((id(*)(id,SEL))original_next)(self,selector);", '''    id drawable = ((id(*)(id,SEL))original_next)(self,selector);
    if ((uintptr_t)(__bridge void *)self == atomic_load(&census_layer_identity)) {
        telar_render_work_pair(render_work_drawable_completions, drawable ? render_work_drawables : render_work_nil_drawables);
    }''')
    replace("        frame->drawable_id = [(id<MTLDrawable>)drawable drawableID];", "        frame->census_layer = (uintptr_t)(__bridge void *)self;\n        frame->drawable_id = [(id<MTLDrawable>)drawable drawableID];")
    replace("            double timestamp = presented.presentedTime;", '''            double timestamp = presented.presentedTime;
            if (frame->census_layer == atomic_load(&census_layer_identity)) {
                telar_render_work_pair(render_work_presentation_callbacks, isfinite(timestamp) && timestamp > 0 ? render_work_positive_presentations : render_work_zero_presentations);
            }''')
    replace("    return ((id(*)(id,SEL,id))original_encoder)(self,selector,pass);", '''    if (census_queue([(id<MTLCommandBuffer>)self commandQueue])) {
        telar_render_work_pair(render_work_passes, texture.iosurface ? render_work_surface_passes : render_work_offscreen_passes);
    }
    return ((id(*)(id,SEL,id))original_encoder)(self,selector,pass);''')
    replace("static void commit(id self, SEL selector) {", '''static void commit(id self, SEL selector) {
    if (census_queue([(id<MTLCommandBuffer>)self commandQueue])) {
        telar_render_work_commit(atomic_load_explicit(&epoch, memory_order_acquire));
    }''')
    replace("static void commit4(id self, SEL selector, const id<MTL4CommandBuffer> *buffers, NSUInteger count, MTL4CommitOptions *options) {", '''static void commit4(id self, SEL selector, const id<MTL4CommandBuffer> *buffers, NSUInteger count, MTL4CommitOptions *options) {
    telar_render_work_record(render_work_unsupported_metal4, 1);''')
    path.write_text(contents)
    commands = [
        ["clang", "-O2", "-Wall", "-Wextra", "-Werror", "-c", str(directory / "render_work_census.c"), "-o", str(directory / "census.o")],
        ["clang", "-dynamiclib", "-O2", "-fobjc-arc", "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "Metal", str(path), str(directory / "census.o"), "-o", str(directory / "probe.dylib")],
    ]
    with (directory / "build.log").open("w") as log:
        for command in commands:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    shutil.copy2(__file__, directory / Path(__file__).name)
    (directory / "build.json").write_text(json.dumps(dict(
        scope="Diagnostic work counts only. Marker-qualified legacy-Metal queue/layer, original typing fixtures and endpoint. No thread CPU sampler.",
        commands=commands, counters=names,
        sha256={file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in directory.iterdir() if file.is_file()},
    ), indent=2) + "\n")
    return directory / "probe.dylib"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    print(build(parser.parse_args().output))
