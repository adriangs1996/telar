#ifndef TELAR_TAB_SWITCH_PHASE_H
#define TELAR_TAB_SWITCH_PHASE_H

#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum { TabPhaseProducers = 4, TabPhaseRecent = 16, TabPhaseMinimum = 8,
       TabPhaseRate = 30, TabPhasePublicationBytes = 20 };
static const double TabPhaseLeadSeconds = .002;

typedef struct {
    double deadline;
    double clearance;
} TabPhasePlan;

static inline void tab_phase_sort(double *values, size_t count) {
    for (size_t index = 1; index < count; ++index) {
        const double value = values[index];
        size_t at = index;
        while (at && values[at - 1] > value) {
            values[at] = values[at - 1];
            --at;
        }
        values[at] = value;
    }
}

// Predict only the initial input phase. Actual publication counts still gate runs.
static inline bool tab_phase_origin(const unsigned char *data, size_t length, double *output) {
    if (!data || !output || length % TabPhasePublicationBytes || length / TabPhasePublicationBytes < TabPhaseMinimum) {
        return false;
    }
    const size_t entries = length / TabPhasePublicationBytes;
    const size_t count = entries < TabPhaseRecent ? entries : TabPhaseRecent;
    double origins[TabPhaseRecent];
    double previous = 0;
    for (size_t index = 0; index < count; ++index) {
        const size_t position = entries - count + index;
        const unsigned char *bytes = data + position * TabPhasePublicationBytes;
        uint32_t generation;
        double before, after;
        memcpy(&generation, bytes, sizeof(generation));
        memcpy(&before, bytes + sizeof(generation), sizeof(before));
        memcpy(&after, bytes + sizeof(generation) + sizeof(before), sizeof(after));
        if (generation != position + 1 || !isfinite(before) || !isfinite(after) || before <= previous || after < before) {
            return false;
        }
        previous = after;
        origins[index] = after - (double)generation / TabPhaseRate;
    }
    tab_phase_sort(origins, count);
    *output = origins[count / 2];
    return isfinite(*output) && *output > 0;
}

static inline bool tab_phase_plan(const double *origins, double now, TabPhasePlan *output) {
    if (!origins || !output || !isfinite(now) || now <= 0) {
        return false;
    }
    const double period = 1.0 / TabPhaseRate;
    double phases[TabPhaseProducers];
    for (size_t index = 0; index < TabPhaseProducers; ++index) {
        if (!isfinite(origins[index]) || origins[index] <= 0 || origins[index] > now) {
            return false;
        }
        phases[index] = fmod(origins[index], period);
    }
    tab_phase_sort(phases, TabPhaseProducers);
    double widest = 0;
    double midpoint = 0;
    for (size_t index = 0; index < TabPhaseProducers; ++index) {
        const double next = index + 1 == TabPhaseProducers ? phases[0] + period : phases[index + 1];
        const double gap = next - phases[index];
        if (gap > widest) {
            widest = gap;
            midpoint = fmod(phases[index] + gap / 2, period);
        }
    }
    double deadline = floor(now / period) * period + midpoint;
    if (deadline <= now + TabPhaseLeadSeconds) {
        deadline += period;
    }
    *output = (TabPhasePlan){deadline, widest / 2};
    return true;
}

#endif
