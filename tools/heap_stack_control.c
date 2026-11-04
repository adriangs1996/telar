#include "heap_stack_census.h"
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#ifdef TELAR_HEAP_STACK_DIRECT_CONTROL
#include "heap_stack_census.c"
#define malloc count_malloc
#define calloc count_calloc
#define realloc count_realloc
#define free count_free
#define aligned_alloc count_aligned
#define posix_memalign count_posix_aligned
#endif

static HeapStackSnapshot result;
static void check(bool condition, unsigned line) {
  if (!condition) {
    fprintf(stderr, "heap stack control failed at line %u\n", line);
    exit(1);
  }
}

#define require(condition) check((condition), __LINE__)

__attribute__((noinline)) static void allocation_site(void) {
  void *first = malloc(31);
  void *second = calloc(3, 17);
  first = realloc(first, 70);
  void *third = aligned_alloc(64, 128);
  void *fourth = NULL;
  require(posix_memalign(&fourth, 64, 64) == 0 && first && second && third);
  memset(first, 1, 70);
  free(first);
  free(second);
  free(third);
  free(fourth);
}

static void *worker(void *unused) {
  (void)unused;
  for (unsigned index = 0; index < 100; ++index) {
    allocation_site();
  }
  return NULL;
}

int main(void) {
#ifdef TELAR_HEAP_STACK_DIRECT_CONTROL
  int (*begin)(unsigned, bool) = telar_heap_stack_begin;
  int (*end)(HeapStackSnapshot *) = telar_heap_stack_end;
#else
  int (*begin)(unsigned, bool) = dlsym(RTLD_DEFAULT, "telar_heap_stack_begin");
  int (*end)(HeapStackSnapshot *) = dlsym(RTLD_DEFAULT, "telar_heap_stack_end");
#endif
  if (!begin || !end) {
    return 2;
  }

  require(begin(heap_stack_max_shift + 1, true) == EINVAL);
  require(begin(0, true) == 0 && begin(0, true) == EBUSY);
  allocation_site();
  errno = 0;
  require(calloc(SIZE_MAX, 2) == NULL && errno == ENOMEM);
  void *invalid = NULL;
  require(posix_memalign(&invalid, 3, 64) == EINVAL && invalid == NULL);
  free(NULL);
  require(end(NULL) == EINVAL && end(&result) == 0 && end(&result) == EINVAL);
  require(result.complete && result.successful_calls == 5 && result.requested_bytes == 344);
  require(result.free_calls == 4 && result.null_returns == 2 && result.used == 5);
  require(!result.overflow && !result.errors && result.end_ns >= result.begin_ns);
  for (unsigned index = 0; index < heap_api_count; ++index) {
    require(result.api_calls[index] == 1);
    const HeapStackRecord *record = &result.records[index];
    require(record->ordinal == index + 1 && record->api == index && record->depth > 2 && record->thread_id);
    require(record->at_ns >= result.begin_ns && record->at_ns <= result.end_ns);
    bool found = false;
    for (unsigned frame = 0; frame < record->depth; ++frame) {
      Dl_info info;
      if (dladdr((void *)(uintptr_t)record->frames[frame], &info) && info.dli_sname && strstr(info.dli_sname, "allocation_site")) {
        found = true;
      }
    }
    require(found);
  }

  require(begin(0, false) == 0);
  allocation_site();
  require(end(&result) == 0 && result.successful_calls == 5 && result.used == 0 && !result.sampling);

  require(begin(0, true) == 0);
  const pid_t child = fork();
  require(child >= 0);
  if (child == 0) {
    allocation_site();
    _exit(0);
  }
  int status;
  require(waitpid(child, &status, 0) == child && status == 0);
  require(end(&result) == 0 && result.successful_calls == 0 && result.used == 0);

  require(begin(3, true) == 0);
  pthread_t threads[2];
  for (unsigned index = 0; index < 2; ++index) {
    require(pthread_create(&threads[index], NULL, worker, NULL) == 0);
  }
  for (unsigned index = 0; index < 2; ++index) {
    require(pthread_join(threads[index], NULL) == 0);
  }
  require(end(&result) == 0 && result.successful_calls >= 1000 && result.used > 20);
  require(!result.overflow && !result.errors);
  uint64_t previous = 0;
  for (unsigned index = 0; index < result.used; ++index) {
    require(result.records[index].ordinal > previous);
    previous = result.records[index].ordinal;
  }

  require(begin(0, true) == 0);
  for (unsigned index = 0; index < heap_stack_capacity + 1; ++index) {
    void *pointer = malloc(1);
    require(pointer != NULL);
    free(pointer);
  }
  require(end(&result) == 0 && result.used == heap_stack_capacity && result.overflow == 1);
  puts("PASS exact API totals, errno, stack sites, disabled sampling, child exclusion, threads and overflow");
  return 0;
}
