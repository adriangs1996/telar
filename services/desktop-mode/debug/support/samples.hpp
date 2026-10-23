#pragma once

#include <algorithm>
#include <cstdio>
#include <vector>

// Timing samples in milliseconds, summarized on one line.
namespace samples {
  inline double percentile(const std::vector<double> &sorted, int percent) {
    const auto index = std::min(sorted.size() - 1, sorted.size() * percent / 100);
    return sorted[index];
  }

  inline void report(const char *label, std::vector<double> values) {
    if (values.empty()) {
      std::printf("  %-8s no samples\n", label);
      return;
    }

    std::sort(values.begin(), values.end());
    double total = 0;
    for (const auto value : values) {
      total += value;
    }

    std::printf("  %-8s p50 %7.3f ms  p95 %7.3f ms  max %7.3f ms  total %8.1f ms\n",
                label,
                percentile(values, 50),
                percentile(values, 95),
                values.back(),
                total);
  }
} // namespace samples
