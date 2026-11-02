// Diagnostic for the Core Video callback cadence used by Qt Cocoa. This does
// not measure drawable presentation or certify a window's frame rate.
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#include <errno.h>
#include <math.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

enum { SampleCapacity = 8192 };
static const double DefaultSeconds = 6;
static const double MaximumSeconds = 30;

typedef struct {
    uint64_t callback_ticks, input_ticks, output_ticks;
    int64_t output_video_time, output_refresh_period;
    int32_t output_time_scale;
    double rate_scalar;
    uint64_t flags;
    atomic_bool ready;
} DisplaySample;

static DisplaySample samples[SampleCapacity];
static atomic_uint sample_count;

static CVReturn observe(const CVTimeStamp *input, const CVTimeStamp *output) {
    unsigned index = atomic_fetch_add_explicit(&sample_count, 1, memory_order_relaxed);

    if (index < SampleCapacity) {
        DisplaySample *sample = &samples[index];
        sample->callback_ticks = mach_absolute_time();
        sample->input_ticks = input->hostTime;
        sample->output_ticks = output->hostTime;
        sample->output_video_time = output->videoTime;
        sample->output_refresh_period = output->videoRefreshPeriod;
        sample->output_time_scale = output->videoTimeScale;
        sample->rate_scalar = output->rateScalar;
        sample->flags = output->flags;
        atomic_store_explicit(&sample->ready, true, memory_order_release);
    }

    return kCVReturnSuccess;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2 || argc > 3) {
            fprintf(stderr, "usage: display-link-probe DISPLAY_ID [SECONDS]\n");
            return EXIT_FAILURE;
        }

        char *end = NULL;
        errno = 0;
        unsigned long display = strtoul(argv[1], &end, 10);
        if (errno || end == argv[1] || *end || !display || display > UINT32_MAX) {
            fprintf(stderr, "invalid display ID\n");
            return EXIT_FAILURE;
        }

        double seconds = DefaultSeconds;
        if (argc == 3) {
            errno = 0;
            seconds = strtod(argv[2], &end);
            if (errno || end == argv[2] || *end || !isfinite(seconds) || seconds <= 0 || seconds > MaximumSeconds) {
                fprintf(stderr, "seconds must be positive and at most %.0f\n", MaximumSeconds);
                return EXIT_FAILURE;
            }
        }

        CGDirectDisplayID display_id = (CGDirectDisplayID)display;
        if (!CGDisplayIsOnline(display_id)) {
            fprintf(stderr, "display is not online\n");
            return EXIT_FAILURE;
        }

        CVDisplayLinkRef link = NULL;
        CVReturn status = CVDisplayLinkCreateWithCGDisplay(display_id, &link);
        if (status == kCVReturnSuccess) {
            status = CVDisplayLinkSetOutputHandler(link, ^CVReturn(CVDisplayLinkRef active, const CVTimeStamp *input, const CVTimeStamp *output, CVOptionFlags flags_in, CVOptionFlags *flags_out) {
                (void)active;
                (void)flags_in;
                (void)flags_out;
                return observe(input, output);
            });
        }
        if (status == kCVReturnSuccess) {
            status = CVDisplayLinkStart(link);
        }

        if (status != kCVReturnSuccess) {
            fprintf(stderr, "cannot start display link: %d\n", status);
            if (link) {
                CVDisplayLinkRelease(link);
            }

            return EXIT_FAILURE;
        }

        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        uint64_t began = mach_absolute_time();
        struct timespec remaining = {.tv_sec = (time_t)seconds,
                                     .tv_nsec = (long)((seconds - floor(seconds)) * 1e9)};
        while (nanosleep(&remaining, &remaining) != 0 && errno == EINTR) {}

        uint64_t ended = mach_absolute_time();
        double actual_period = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link);
        CVTime nominal_period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link);
        CGDirectDisplayID actual_display = CVDisplayLinkGetCurrentCGDisplay(link);
        CVDisplayLinkStop(link);
        CVDisplayLinkRelease(link);

        unsigned count = atomic_load_explicit(&sample_count, memory_order_acquire);
        NSMutableArray *observations = [NSMutableArray array];
        for (unsigned index = 0; index < MIN(count, SampleCapacity); ++index) {
            DisplaySample *sample = &samples[index];
            if (!atomic_load_explicit(&sample->ready, memory_order_acquire)) {
                continue;
            }

            [observations addObject:@[@(sample->callback_ticks), @(sample->input_ticks), @(sample->output_ticks),
                @(sample->output_video_time), @(sample->output_refresh_period), @(sample->output_time_scale),
                @(sample->rate_scalar), @(sample->flags)]];
        }

        double elapsed = (double)(ended - began) * timebase.numer / timebase.denom / 1e9;
        BOOL valid = count >= 2 && count <= SampleCapacity && observations.count == count && actual_display == display_id && elapsed >= seconds;
        NSDictionary *result = @{
            @"valid": @(valid), @"endpoint": @"Core Video callback, not drawable presentation",
            @"requested_display_id": @(display_id), @"actual_display_id": @(actual_display),
            @"duration_requested_seconds": @(seconds), @"began_ticks": @(began), @"ended_ticks": @(ended),
            @"duration_observed_seconds": @(elapsed),
            @"timebase_numer": @(timebase.numer), @"timebase_denom": @(timebase.denom),
            @"actual_period_seconds": @(actual_period),
            @"nominal_period": @{@"value": @(nominal_period.timeValue), @"scale": @(nominal_period.timeScale), @"flags": @(nominal_period.flags)},
            @"callback_count": @(count), @"sample_capacity": @(SampleCapacity),
            @"columns": @[@"callback_ticks", @"input_host_ticks", @"output_host_ticks", @"output_video_time",
                          @"output_refresh_period", @"output_time_scale", @"rate_scalar", @"output_flags"],
            @"samples": observations,
        };
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
        if (!json || fwrite(json.bytes, 1, json.length, stdout) != json.length) {
            fprintf(stderr, "cannot write diagnostic result\n");
            return EXIT_FAILURE;
        }

        fputc('\n', stdout);
        return valid ? EXIT_SUCCESS : EXIT_FAILURE;
    }
}
