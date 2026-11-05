// Darwin-only diagnostic. Parse the bounded mapping only after process exit.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <os/lock.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

enum { record_capacity = 16384, byte_capacity = 4 * 1024 * 1024, trace_version = 1 };
static const uint64_t trace_magic = UINT64_C(0x31524452595450);

typedef struct {
  uint64_t magic, version, records_capacity, bytes_capacity;
  uint64_t records_used, bytes_used, overflow, complete;
} Header;

typedef struct {
  uint64_t begin_ns, end_ns, pid, descriptor, requested;
  int64_t result;
  uint64_t error, offset, length, ready;
} Record;

typedef struct {
  Header header;
  Record records[record_capacity];
  unsigned char bytes[byte_capacity];
} Trace;

_Static_assert(sizeof(Header) == 64, "Trace header layout changed");
_Static_assert(sizeof(Record) == 80, "Trace record layout changed");
static Trace *trace;
static pid_t owner;
static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;

__attribute__((constructor)) static void initialize(void) {
  const char *expected = getenv("PTY_READ_EXECUTABLE");
  const char *prefix = getenv("PTY_READ_PREFIX");
  char executable[PATH_MAX], resolved[PATH_MAX], path[PATH_MAX];
  uint32_t capacity = sizeof(executable);
  if (!expected || !prefix || _NSGetExecutablePath(executable, &capacity) != 0 ||
      !realpath(executable, resolved) || strcmp(resolved, expected) != 0) {
    return;
  }

  owner = getpid();
  const int length = snprintf(path, sizeof(path), "%s.%d.bin", prefix, owner);
  if (length < 0 || (size_t)length >= sizeof(path)) {
    _exit(125);
  }

  const int file = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (file < 0 || ftruncate(file, sizeof(Trace)) != 0) {
    _exit(125);
  }

  trace = mmap(NULL, sizeof(Trace), PROT_READ | PROT_WRITE, MAP_SHARED, file, 0);
  close(file);
  if (trace == MAP_FAILED) {
    _exit(125);
  }

  trace->header = (Header){.magic = trace_magic, .version = trace_version,
                          .records_capacity = record_capacity, .bytes_capacity = byte_capacity};
}

__attribute__((destructor)) static void finish(void) {
  if (trace && getpid() == owner) {
    os_unfair_lock_lock(&lock);
    trace->header.complete = 1;
    os_unfair_lock_unlock(&lock);
  }
}

static void capture(Record observation, const struct iovec *vectors, int count) {
  const size_t length = observation.result > 0 ? (size_t)observation.result : 0;
  os_unfair_lock_lock(&lock);
  Header *header = &trace->header;
  if (header->records_used == record_capacity || length > byte_capacity - header->bytes_used) {
    ++header->overflow;
  } else {
    Record *record = &trace->records[header->records_used++];
    *record = observation;
    record->pid = (uint64_t)owner;
    record->offset = header->bytes_used;
    record->length = length;
    size_t copied = 0;
    for (int index = 0; index < count && copied < length; ++index) {
      const size_t available = length - copied;
      const size_t amount = vectors[index].iov_len < available ? vectors[index].iov_len : available;
      if (amount) {
        memcpy(trace->bytes + header->bytes_used + copied, vectors[index].iov_base, amount);
      }

      copied += amount;
    }

    if (copied != length) {
      ++header->overflow;
    }

    header->bytes_used += length;
    record->ready = 1;
  }

  os_unfair_lock_unlock(&lock);
}

static ssize_t observed_read(int descriptor, void *buffer, size_t capacity) {
  const int incoming_error = errno;
  const int observe = trace && getpid() == owner && isatty(descriptor);
  const uint64_t begin = observe ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
  errno = incoming_error;
  const ssize_t result = read(descriptor, buffer, capacity);
  const int error = errno;
  if (observe) {
    const struct iovec vector = {.iov_base = buffer, .iov_len = capacity};
    capture((Record){.begin_ns = begin, .end_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                      .descriptor = (uint64_t)descriptor, .requested = capacity,
                      .result = result, .error = (uint64_t)error}, &vector, 1);
  }

  errno = error;
  return result;
}

static ssize_t observed_readv(int descriptor, const struct iovec *vectors, int count) {
  const int incoming_error = errno;
  const int observe = trace && getpid() == owner && isatty(descriptor);
  const uint64_t begin = observe ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
  errno = incoming_error;
  const ssize_t result = readv(descriptor, vectors, count);
  const int error = errno;
  if (observe) {
    const uint64_t end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t requested = 0;
    // Failed calls need not expose readable iovecs, for example EFAULT.
    if (result >= 0) {
      for (int index = 0; index < count; ++index) {
        const uint64_t length = vectors[index].iov_len;
        requested = length > UINT64_MAX - requested ? UINT64_MAX : requested + length;
      }
    }

    capture((Record){.begin_ns = begin, .end_ns = end, .descriptor = (uint64_t)descriptor,
                      .requested = requested, .result = result, .error = (uint64_t)error},
            vectors, result > 0 ? count : 0);
  }

  errno = error;
  return result;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
  const void *replacement;
  const void *original;
} read_interpose[] = {
    {(const void *)observed_read, (const void *)read},
    {(const void *)observed_readv, (const void *)readv},
};
