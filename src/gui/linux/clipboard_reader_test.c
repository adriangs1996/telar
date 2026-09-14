#define _POSIX_C_SOURCE 200809L
#include "clipboard_reader.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void check_completion(void) {
    telar_clipboard_reader reader;
    telar_clipboard_reader_init(&reader);
    int pipe_fd[2];
    assert(pipe(pipe_fd) == 0);
    assert(telar_clipboard_reader_begin(&reader, pipe_fd[0], 31, 100));
    assert(telar_clipboard_reader_timeout(&reader, 100) == 5000);
    assert(write(pipe_fd[1], "hello", 5) == 5);
    telar_clipboard_reader_dispatch(&reader, 101);
    assert(reader.pending && !reader.ready && reader.len == 5);
    close(pipe_fd[1]);
    telar_clipboard_reader_dispatch(&reader, 102);
    assert(reader.ready && reader.fd == -1 && reader.request_id == 31 && reader.status == TELAR_CLIPBOARD_READ_OK);
    assert(telar_clipboard_reader_timeout(&reader, 102) == -1);
    assert(!memcmp(reader.bytes, "hello", 5));
    telar_clipboard_reader_dispatch(&reader, 99999);
    assert(reader.len == 5 && reader.status == TELAR_CLIPBOARD_READ_OK); // Backpressure retains the complete result.
    int next[2];
    assert(pipe(next) == 0);
    assert(!telar_clipboard_reader_begin(&reader, next[0], 32, 200));
    close(next[0]);
    close(next[1]);
    telar_clipboard_reader_release(&reader);
    assert(!reader.pending && telar_clipboard_reader_timeout(&reader, 102) == -1);
}

static void check_bound(bool extra) {
    telar_clipboard_reader reader;
    telar_clipboard_reader_init(&reader);
    int fds[2];
    assert(pipe(fds) == 0);
    assert(telar_clipboard_reader_begin(&reader, fds[0], 44, 100));
    uint8_t chunk[1024];
    memset(chunk, 'x', sizeof chunk);
    for (unsigned i = 0; i < TELAR_CLIPBOARD_LIMIT / sizeof chunk; i++) {
        assert(write(fds[1], chunk, sizeof chunk) == sizeof chunk);
        telar_clipboard_reader_dispatch(&reader, 101);
    }
    if (extra) assert(write(fds[1], "x", 1) == 1);
    close(fds[1]);
    telar_clipboard_reader_dispatch(&reader, 102);
    assert(reader.ready && reader.fd == -1);
    assert(reader.status == (extra ? TELAR_CLIPBOARD_READ_TOO_LARGE : TELAR_CLIPBOARD_READ_OK));
    assert(reader.len == (extra ? 0 : TELAR_CLIPBOARD_LIMIT));
    telar_clipboard_reader_release(&reader);
}

static void check_lifecycle(void) {
    telar_clipboard_reader reader;
    telar_clipboard_reader_init(&reader);
    for (unsigned cancel = 0; cancel < 2; cancel++) {
        int fds[2];
        assert(pipe(fds) == 0);
        assert(telar_clipboard_reader_begin(&reader, fds[0], 50 + cancel, 100));
        if (cancel) telar_clipboard_reader_cancel(&reader);
        else telar_clipboard_reader_dispatch(&reader, 5100);
        assert(reader.ready && reader.fd == -1 && reader.len == 0);
        assert(reader.status == (cancel ? TELAR_CLIPBOARD_READ_CANCELLED : TELAR_CLIPBOARD_READ_FAILED));
        assert(fcntl(fds[0], F_GETFD) == -1);
        close(fds[1]);
        telar_clipboard_reader_release(&reader);
    }
}

static void check_utf8(void) {
    const char *values[] = {"界é", "\xff", "\xc0\xaf", "\xed\xa0\x80", "\xe4\xbd"};
    for (unsigned i = 0; i < sizeof values / sizeof *values; i++) {
        telar_clipboard_reader reader;
        telar_clipboard_reader_init(&reader);
        int fds[2];
        assert(pipe(fds) == 0);
        assert(telar_clipboard_reader_begin(&reader, fds[0], 71, 0));
        size_t len = strlen(values[i]);
        // A scalar may span several readiness notifications.
        assert(write(fds[1], values[i], 1) == 1);
        telar_clipboard_reader_dispatch(&reader, 1);
        assert(!reader.ready);
        assert(write(fds[1], values[i] + 1, len - 1) == (ssize_t)(len - 1));
        close(fds[1]);
        telar_clipboard_reader_dispatch(&reader, 2);
        assert(reader.ready && reader.request_id == 71);
        assert(reader.status == (i == 0 ? TELAR_CLIPBOARD_READ_OK : TELAR_CLIPBOARD_READ_FAILED));
        assert(reader.len == (i == 0 ? len : 0));
        telar_clipboard_reader_release(&reader);
        assert(telar_clipboard_reader_timeout(&reader, 3) == -1);
    }
}

static void check_dispatch_budget(void) {
    FILE *file = tmpfile();
    assert(file != NULL);
    uint8_t chunk[4096];
    memset(chunk, 'x', sizeof chunk);
    for (unsigned i = 0; i < 8; i++) assert(fwrite(chunk, 1, sizeof chunk, file) == sizeof chunk);
    assert(fflush(file) == 0 && fseek(file, 0, SEEK_SET) == 0);
    int fd = dup(fileno(file));
    assert(fd >= 0);
    fclose(file);
    telar_clipboard_reader reader;
    telar_clipboard_reader_init(&reader);
    assert(telar_clipboard_reader_begin(&reader, fd, 81, 100));
    telar_clipboard_reader_dispatch(&reader, 101);
    assert(reader.len == 16 * 1024 && !reader.ready && reader.deadline_ms == 5100);
    telar_clipboard_reader_dispatch(&reader, 102);
    assert(reader.len == 32 * 1024 && !reader.ready && reader.deadline_ms == 5100);
    telar_clipboard_reader_dispatch(&reader, 103);
    assert(reader.ready && reader.status == TELAR_CLIPBOARD_READ_OK && reader.len == 32 * 1024);
    telar_clipboard_reader_release(&reader);
}

int main(void) {
    check_completion();
    check_bound(false);
    check_bound(true);
    check_lifecycle();
    check_utf8();
    check_dispatch_budget();
    puts("Wayland clipboard reader: request identity, complete ownership, bounds, backpressure, deadline and cancellation passed");
    return 0;
}
