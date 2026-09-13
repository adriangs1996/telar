#define _POSIX_C_SOURCE 200809L
#include "clipboard.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// The window producer writes only free slots; the worker owns each descriptor
// and immutable byte snapshot from publication through close.
struct transfer {
    atomic_bool active;
    int fd;
    uint8_t bytes[TELAR_CLIPBOARD_LIMIT];
    size_t len, offset;
    int64_t deadline;
};

struct telar_clipboard {
    struct wl_data_source *source;
    uint8_t bytes[TELAR_CLIPBOARD_LIMIT];
    size_t len;
    struct transfer transfers[TELAR_CLIPBOARD_TRANSFERS];
    pthread_t worker;
    int wake[2];
    atomic_bool stopping;
};

static int64_t now_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static bool configure_fd(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 &&
           fcntl(fd, F_SETFD, FD_CLOEXEC) == 0;
}

static void wake(telar_clipboard *self) {
    const uint8_t byte = 1;
    ssize_t written;
    do {
        written = write(self->wake[1], &byte, 1);
    } while (written < 0 && errno == EINTR);
}

static void finish(struct transfer *transfer) {
    close(transfer->fd);
    atomic_store_explicit(&transfer->active, false, memory_order_release);
}

static void *run(void *context) {
    telar_clipboard *self = context;
    // A receiver may close its pipe without consuming the clipboard. Keep
    // SIGPIPE local to this worker so that failure only retires that transfer.
    sigset_t signals;
    sigemptyset(&signals);
    sigaddset(&signals, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &signals, NULL);
    while (!atomic_load_explicit(&self->stopping, memory_order_acquire)) {
        struct pollfd fds[1 + TELAR_CLIPBOARD_TRANSFERS] = {{.fd = self->wake[0], .events = POLLIN}};
        int timeout = -1;
        const int64_t now = now_ms();
        for (size_t index = 0; index < TELAR_CLIPBOARD_TRANSFERS; index++) {
            struct transfer *transfer = &self->transfers[index];
            fds[index + 1].fd = -1;
            if (atomic_load_explicit(&transfer->active, memory_order_acquire)) {
                const int64_t remaining = transfer->deadline - now;
                int wait = remaining <= 0 ? 0 : (int)remaining;
                timeout = timeout < 0 || wait < timeout ? wait : timeout;
                fds[index + 1] = (struct pollfd){.fd = transfer->fd, .events = POLLOUT};
            }
        }

        int ready = poll(fds, 1 + TELAR_CLIPBOARD_TRANSFERS, timeout);
        if (ready < 0 && errno == EINTR) {
            continue;
        }

        if (ready < 0) {
            break;
        }

        if (fds[0].revents & POLLIN) {
            uint8_t bytes[64];
            while (read(self->wake[0], bytes, sizeof bytes) > 0) {}
        }

        for (size_t index = 0; index < TELAR_CLIPBOARD_TRANSFERS; index++) {
            struct transfer *transfer = &self->transfers[index];
            if (fds[index + 1].fd < 0) {
                continue;
            }

            if ((fds[index + 1].revents & (POLLERR | POLLHUP | POLLNVAL)) || now_ms() >= transfer->deadline) {
                finish(transfer);
                continue;
            }

            if (!(fds[index + 1].revents & POLLOUT)) {
                continue;
            }

            ssize_t written = write(transfer->fd, transfer->bytes + transfer->offset, transfer->len - transfer->offset);
            if (written < 0) {
                if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                    finish(transfer);
                }
                continue;
            }

            transfer->offset += (size_t)written;
            if (transfer->offset == transfer->len) {
                finish(transfer);
            }
        }
    }

    for (size_t index = 0; index < TELAR_CLIPBOARD_TRANSFERS; index++) {
        if (atomic_load_explicit(&self->transfers[index].active, memory_order_acquire)) {
            finish(&self->transfers[index]);
        }
    }

    return NULL;
}

static void target(void *context, struct wl_data_source *source, const char *mime) {
    (void)context; (void)source; (void)mime;
}

static void send_selection(void *context, struct wl_data_source *source, const char *mime, int fd) {
    telar_clipboard *self = context;
    if (atomic_load_explicit(&self->stopping, memory_order_acquire) || source != self->source || mime == NULL ||
        (strcmp(mime, "text/plain;charset=utf-8") && strcmp(mime, "text/plain")) || !configure_fd(fd)) {
        close(fd);
        return;
    }

    for (size_t index = 0; index < TELAR_CLIPBOARD_TRANSFERS; index++) {
        struct transfer *transfer = &self->transfers[index];
        if (!atomic_load_explicit(&transfer->active, memory_order_acquire)) {
            transfer->fd = fd;
            transfer->len = self->len;
            transfer->offset = 0;
            transfer->deadline = now_ms() + 5000;
            memcpy(transfer->bytes, self->bytes, self->len);
            atomic_store_explicit(&transfer->active, true, memory_order_release);
            wake(self);
            return;
        }
    }

    close(fd);
}

static void cancelled(void *context, struct wl_data_source *source) {
    telar_clipboard *self = context;
    if (self->source == source) {
        self->source = NULL;
    }

    wl_data_source_destroy(source);
}

static const struct wl_data_source_listener listener = {.target = target, .send = send_selection, .cancelled = cancelled};

telar_clipboard *telar_clipboard_create(void) {
    telar_clipboard *self = calloc(1, sizeof *self);
    if (self == NULL) {
        return NULL;
    }

    atomic_init(&self->stopping, false);
    for (size_t index = 0; index < TELAR_CLIPBOARD_TRANSFERS; index++) {
        atomic_init(&self->transfers[index].active, false);
    }

    if (pipe(self->wake) != 0) {
        free(self);
        return NULL;
    }

    if (!configure_fd(self->wake[0]) || !configure_fd(self->wake[1]) || pthread_create(&self->worker, NULL, run, self) != 0) {
        close(self->wake[0]);
        close(self->wake[1]);
        free(self);
        return NULL;
    }

    return self;
}

void telar_clipboard_destroy(telar_clipboard *self) {
    if (self == NULL) {
        return;
    }

    if (self->source != NULL) {
        wl_data_source_destroy(self->source);
    }

    atomic_store_explicit(&self->stopping, true, memory_order_release);
    wake(self);
    pthread_join(self->worker, NULL);
    close(self->wake[0]);
    close(self->wake[1]);
    free(self);
}

bool telar_clipboard_publish(telar_clipboard *self, const telar_clipboard_offer *offer) {
    if (atomic_load_explicit(&self->stopping, memory_order_acquire) || offer->manager == NULL || offer->device == NULL || offer->serial == 0 ||
        offer->len > TELAR_CLIPBOARD_LIMIT || (offer->len != 0 && offer->bytes == NULL)) {
        return false;
    }

    struct wl_data_source *source = wl_data_device_manager_create_data_source(offer->manager);
    if (source == NULL) {
        return false;
    }

    wl_data_source_add_listener(source, &listener, self);
    wl_data_source_offer(source, "text/plain;charset=utf-8");
    wl_data_source_offer(source, "text/plain");
    struct wl_data_source *previous = self->source;
    self->source = source;
    self->len = offer->len;
    if (offer->len != 0) {
        memcpy(self->bytes, offer->bytes, offer->len);
    }
    wl_data_device_set_selection(offer->device, source, offer->serial);
    if (previous != NULL) {
        wl_data_source_destroy(previous);
    }

    return true;
}
