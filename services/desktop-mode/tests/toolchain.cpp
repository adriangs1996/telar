#include <cstdio>
#include <generator>
#include <thread>

import app_context;
import runtime_receiver_worker;

#ifndef __cpp_lib_generator
#error "The selected standard library must provide std::generator"
#endif

static_assert(sizeof(EventQueue) > 0);
static_assert(sizeof(RuntimeReceiverWorker) > 0);

std::generator<int> values() {
  co_yield 1;
  co_yield 2;
}

int main() {
  int total = 0;

  for (const int value : values()) {
    total += value;
  }

  int threaded_value = 0;
  std::jthread worker([&] { threaded_value = total; });
  worker.join();

  if (threaded_value != 3) {
    return 1;
  }

  std::puts("C++23 generator and modules OK");
}
