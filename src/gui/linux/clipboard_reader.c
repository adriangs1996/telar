#include "clipboard_reader.h"
#include <errno.h>
#include <fcntl.h>
#include <glib.h>
#include <string.h>
#include <unistd.h>

static void finish(telar_clipboard_reader *self, enum telar_clipboard_read_status status) {
    if (self->fd >= 0) {
        close(self->fd);
        self->fd = -1;
    }
    self->ready = true;
    self->status = status;
    if (status != TELAR_CLIPBOARD_READ_OK) self->len = 0;
}

void telar_clipboard_reader_init(telar_clipboard_reader *self) {
    *self = (telar_clipboard_reader){.fd = -1};
}

bool telar_clipboard_reader_begin(telar_clipboard_reader *self, int fd, uint64_t request_id, int64_t now_ms) {
    if (self->pending || fd < 0) return false;
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) return false;
    self->fd = fd;
    self->pending = true;
    self->ready = false;
    self->request_id = request_id;
    self->deadline_ms = now_ms + 5000;
    self->len = 0;
    return true;
}

void telar_clipboard_reader_dispatch(telar_clipboard_reader *self, int64_t now_ms) {
    if (!self->pending || self->ready) return;
    if (now_ms >= self->deadline_ms) {
        finish(self, TELAR_CLIPBOARD_READ_FAILED);
        return;
    }

    uint8_t chunk[4096];
    size_t remaining = 16 * 1024;
    for (unsigned attempts = 0; attempts < 16 && remaining != 0; attempts++) {
        size_t capacity = remaining < sizeof chunk ? remaining : sizeof chunk;
        ssize_t count = read(self->fd, chunk, capacity);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (count < 0) {
            finish(self, TELAR_CLIPBOARD_READ_FAILED);
            return;
        }
        if (count == 0) {
            bool valid = self->len == 0 || g_utf8_validate((const char *)self->bytes, (gssize)self->len, NULL);
            finish(self, valid ? TELAR_CLIPBOARD_READ_OK : TELAR_CLIPBOARD_READ_FAILED);
            return;
        }
        if ((size_t)count > sizeof self->bytes - self->len) {
            finish(self, TELAR_CLIPBOARD_READ_TOO_LARGE);
            return;
        }
        memcpy(self->bytes + self->len, chunk, (size_t)count);
        self->len += (size_t)count;
        remaining -= (size_t)count;
    }
}

void telar_clipboard_reader_cancel(telar_clipboard_reader *self) {
    if (self->pending) finish(self, TELAR_CLIPBOARD_READ_CANCELLED);
}

void telar_clipboard_reader_release(telar_clipboard_reader *self) {
    if (self->fd >= 0) close(self->fd);
    self->fd = -1;
    self->pending = self->ready = false;
    self->len = 0;
}

int telar_clipboard_reader_timeout(const telar_clipboard_reader *self, int64_t now_ms) {
    if (!self->pending) return -1;
    if (self->ready) return -1;
    int64_t remaining = self->deadline_ms - now_ms;
    return remaining <= 0 ? 0 : remaining > 5000 ? 5000 : (int)remaining;
}
