#define _GNU_SOURCE
// Unit tests own the protocol callback boundary without opening a compositor.
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>

static int injected_poll(struct pollfd *, nfds_t, int);
static int joined_worker(pthread_t, void **);
#define poll injected_poll
#define pthread_join joined_worker
#include "clipboard.c"
#undef pthread_join
#undef poll
#include <stdio.h>

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "clipboard check failed at line %d: %s\n", __LINE__, #condition); return false; } } while (0)

static struct wl_data_source *const fake_source = (struct wl_data_source *)(uintptr_t)1;
static atomic_bool fail_next_poll;
static void (*after_worker_join)(void *);
static void *after_worker_join_context;

static int injected_poll(struct pollfd *fds, nfds_t count, int timeout) {
    if (atomic_exchange_explicit(&fail_next_poll, false, memory_order_acq_rel)) {
        errno = ENOMEM;
        return -1;
    }

    return poll(fds, count, timeout);
}

static int joined_worker(pthread_t worker, void **result) {
    int status = pthread_join(worker, result);
    if (status == 0 && after_worker_join != NULL) {
        after_worker_join(after_worker_join_context);
    }

    return status;
}

static bool pipe_snapshot(void) {
    telar_clipboard *clipboard = telar_clipboard_create();
    CHECK(clipboard != NULL);
    clipboard->source = fake_source;
    clipboard->len = TELAR_CLIPBOARD_LIMIT;
    memset(clipboard->bytes, 'a', clipboard->len);
    int fds[2];
    CHECK(pipe(fds) == 0);
    CHECK(fcntl(fds[1], F_SETPIPE_SZ, 4096) >= 0);
    send_selection(clipboard, fake_source, "text/plain;charset=utf-8", fds[1]);
    memset(clipboard->bytes, 'b', clipboard->len);
    uint8_t bytes[1024];
    size_t received = 0;
    ssize_t count;
    while ((count = read(fds[0], bytes, sizeof bytes)) > 0) {
        for (ssize_t index = 0; index < count; index++) {
            CHECK(bytes[index] == 'a');
        }
        received += (size_t)count;
    }
    CHECK(count == 0 && received == TELAR_CLIPBOARD_LIMIT);
    close(fds[0]);
    clipboard->source = NULL;
    telar_clipboard_destroy(clipboard);
    return true;
}

static bool bounded_transfers(void) {
    telar_clipboard *clipboard = telar_clipboard_create();
    CHECK(clipboard != NULL);
    clipboard->source = fake_source;
    clipboard->len = TELAR_CLIPBOARD_LIMIT;
    memset(clipboard->bytes, 'x', clipboard->len);
    int readers[TELAR_CLIPBOARD_TRANSFERS];
    for (size_t index = 0; index < TELAR_CLIPBOARD_TRANSFERS; index++) {
        int fds[2];
        CHECK(pipe(fds) == 0);
        CHECK(fcntl(fds[1], F_SETPIPE_SZ, 4096) >= 0);
        readers[index] = fds[0];
        send_selection(clipboard, fake_source, "text/plain", fds[1]);
    }
    int overflow[2];
    CHECK(pipe(overflow) == 0);
    send_selection(clipboard, fake_source, "text/plain", overflow[1]);
    uint8_t byte;
    CHECK(read(overflow[0], &byte, 1) == 0);
    close(overflow[0]);
    for (size_t index = 0; index < TELAR_CLIPBOARD_TRANSFERS; index++) {
        close(readers[index]);
    }
    const int64_t deadline = now_ms() + 1000;
    size_t active;
    do {
        active = 0;
        for (size_t index = 0; index < TELAR_CLIPBOARD_TRANSFERS; index++) {
            active += atomic_load_explicit(&clipboard->transfers[index].active, memory_order_acquire);
        }
        const struct timespec delay = {.tv_nsec = 1000000};
        nanosleep(&delay, NULL);
    } while (active != 0 && now_ms() < deadline);
    CHECK(active == 0);
    clipboard->source = NULL;
    telar_clipboard_destroy(clipboard);
    return true;
}

static bool shutdown_cancels_stalled_reader(void) {
    telar_clipboard *clipboard = telar_clipboard_create();
    CHECK(clipboard != NULL);
    clipboard->source = fake_source;
    clipboard->len = TELAR_CLIPBOARD_LIMIT;
    int fds[2];
    CHECK(pipe(fds) == 0);
    CHECK(fcntl(fds[1], F_SETPIPE_SZ, 4096) >= 0);
    send_selection(clipboard, fake_source, "text/plain", fds[1]);
    clipboard->source = NULL;
    const int64_t start = now_ms();
    telar_clipboard_destroy(clipboard);
    CHECK(now_ms() - start < 1000);
    close(fds[0]);
    return true;
}

struct late_publication {
    telar_clipboard *clipboard;
    int fd;
};

static void publish_after_worker_exit(void *context) {
    const struct late_publication *publication = context;
    struct transfer *transfer = &publication->clipboard->transfers[0];
    // Model a producer that passed admission before the worker failed and
    // published after its last sweep. Joining makes this ordering deterministic.
    transfer->fd = publication->fd;
    transfer->len = transfer->offset = 0;
    atomic_store_explicit(&transfer->active, true, memory_order_release);
}

static bool poll_failure_revokes_admission_and_reclaims_late_publication(void) {
    atomic_store_explicit(&fail_next_poll, true, memory_order_release);
    telar_clipboard *clipboard = telar_clipboard_create();
    CHECK(clipboard != NULL);
    const int64_t deadline = now_ms() + 1000;
    while (!atomic_load_explicit(&clipboard->stopping, memory_order_acquire) && now_ms() < deadline) {
        const struct timespec delay = {.tv_nsec = 1000000};
        nanosleep(&delay, NULL);
    }
    CHECK(atomic_load_explicit(&clipboard->stopping, memory_order_acquire));
    CHECK(!atomic_load_explicit(&fail_next_poll, memory_order_acquire));

    int rejected[2];
    CHECK(pipe(rejected) == 0);
    CHECK(configure_fd(rejected[0]));
    clipboard->source = fake_source;
    send_selection(clipboard, fake_source, "text/plain", rejected[1]);
    uint8_t byte;
    CHECK(read(rejected[0], &byte, 1) == 0);
    close(rejected[0]);

    int late[2];
    CHECK(pipe(late) == 0);
    CHECK(configure_fd(late[0]));
    struct late_publication publication = {.clipboard = clipboard, .fd = late[1]};
    after_worker_join = publish_after_worker_exit;
    after_worker_join_context = &publication;
    clipboard->source = NULL;
    telar_clipboard_destroy(clipboard);
    after_worker_join = NULL;
    after_worker_join_context = NULL;
    errno = 0;
    CHECK(fcntl(late[1], F_GETFD) == -1 && errno == EBADF);
    CHECK(read(late[0], &byte, 1) == 0);
    close(late[0]);
    return true;
}

int main(void) {
    if (!pipe_snapshot() || !bounded_transfers() || !shutdown_cancels_stalled_reader() ||
        !poll_failure_revokes_admission_and_reclaims_late_publication()) {
        return 1;
    }
    puts("native Linux clipboard: snapshots, backpressure, closed receivers, worker failure and shutdown passed");
    return 0;
}
