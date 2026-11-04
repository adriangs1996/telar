#pragma once

// In-process diagnostic only. Calls must be paired on the same controlling thread.
int telar_thread_cpu_begin(const char *path);
int telar_thread_cpu_end(void);
