#define _GNU_SOURCE
// Unit tests own the protocol callback boundary without opening a compositor.
#include "clipboard.c"
#include <stdio.h>

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "clipboard check failed at line %d: %s\n", __LINE__, #condition); return false; } } while (0)

static struct wl_data_source *const fake_source = (struct wl_data_source *)(uintptr_t)1;

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

int main(void) {
    if (!pipe_snapshot() || !bounded_transfers() || !shutdown_cancels_stalled_reader()) {
        return 1;
    }
    puts("native Linux clipboard: snapshots, backpressure, closed receivers and shutdown passed");
    return 0;
}
