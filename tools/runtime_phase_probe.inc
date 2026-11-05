#include "macos_process_resources_json.h"
#include <limits.h>

static ProcessResources runtime_phase_ready;
static double runtime_phase_ready_before;
static double runtime_phase_ready_after;
static ProcessResources runtime_phase_start;
static double runtime_phase_start_before;
static double runtime_phase_start_after;
static BOOL runtime_phase_active;

static void runtime_phase_prepare(void) {
    const char *value = getenv("TGB_RUNTIME_PHASE_PID");
    char *end = NULL;
    errno = 0;
    const long pid = value ? strtol(value, &end, 10) : 0;
    if (!value || errno || end == value || *end || pid <= 0 || pid > INT_MAX || runtime_phase_ready.pid != 0) {
        _exit(75);
    }
    runtime_phase_ready_before = CACurrentMediaTime();
    runtime_phase_ready = process_resources((pid_t)pid);
    runtime_phase_ready_after = CACurrentMediaTime();
}

static void runtime_phase_begin(void) {
    if (runtime_phase_ready.pid <= 0 || runtime_phase_active) {
        _exit(75);
    }
    runtime_phase_start_before = CACurrentMediaTime();
    runtime_phase_start = process_resources(runtime_phase_ready.pid);
    runtime_phase_start_after = CACurrentMediaTime();
    runtime_phase_active = YES;
}

static void runtime_phase_end(const char *path) {
    if (!runtime_phase_active) {
        return;
    }
    const double before = CACurrentMediaTime();
    const ProcessResources end = process_resources(runtime_phase_start.pid);
    const double after = CACurrentMediaTime();
    runtime_phase_active = NO;
    if (!process_resources_match(&runtime_phase_ready, &runtime_phase_start) || !process_resources_match(&runtime_phase_start, &end)) {
        _exit(75);
    }
    FILE *output = fopen(path, "wx");
    if (!output) {
        _exit(75);
    }
    BOOL valid = fprintf(output, "{\"scope\":\"Diagnostic runtime counters around measured GUI actions; observer timings are not acceptance evidence\",\"ready_ca_before\":%.17g,\"ready_ca_after\":%.17g,\"start_ca_before\":%.17g,\"start_ca_after\":%.17g,\"end_ca_before\":%.17g,\"end_ca_after\":%.17g,\"snapshots\":[", runtime_phase_ready_before, runtime_phase_ready_after, runtime_phase_start_before, runtime_phase_start_after, before, after) > 0;
    valid = process_resources_write(output, &runtime_phase_ready) && valid;
    valid = fprintf(output, ",") > 0 && valid;
    valid = process_resources_write(output, &runtime_phase_start) && valid;
    valid = fprintf(output, ",") > 0 && valid;
    valid = process_resources_write(output, &end) && valid;
    valid = fprintf(output, "]}\n") > 0 && valid;
    const int closed = fclose(output);
    if (!valid || closed != 0) {
        _exit(75);
    }
}
