#pragma once

// In-process diagnostic only. Calls must be paired on the same controlling thread.
enum TelarThreadCpuSampling {
  telar_thread_cpu_periodic,
  telar_thread_cpu_boundaries
};

int telar_thread_cpu_begin(const char *path);
int telar_thread_cpu_begin_sampling(const char *path, enum TelarThreadCpuSampling sampling);
int telar_thread_cpu_end(void);
