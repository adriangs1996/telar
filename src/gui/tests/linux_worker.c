#define _POSIX_C_SOURCE 200809L
#include "../linux/frame_worker.h"
#include <assert.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

// A blocked consumer proves that destroy joins before borrowed storage can die.
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static bool entered, release_render;
static atomic_bool destroyed;
static telar_frame_worker *worker;
static const telar_gui_quad quad = {.width = 42};

enum telar_render_result telar_renderer_draw(telar_renderer *renderer, telar_gui_viewport viewport,
                                             const telar_gui_frame *frame) {
    (void)renderer;
    assert(viewport.width == 640);
    pthread_mutex_lock(&mutex);
    entered = true;
    pthread_cond_broadcast(&condition);
    while (!release_render) {
        pthread_cond_wait(&condition, &mutex);
    }
    assert(frame->token == 9 && frame->quads->width == 42);
    pthread_mutex_unlock(&mutex);
    return TELAR_RENDER_DELIVERED;
}

static void *close_worker(void *unused) {
    (void)unused;
    telar_frame_worker_destroy(worker);
    atomic_store(&destroyed, true);
    return NULL;
}

int main(void) {
    worker = telar_frame_worker_create(NULL);
    assert(worker != NULL);
    telar_gui_frame frame = {.token = 9, .quads = &quad, .quad_count = 1};
    assert(telar_frame_worker_submit(worker, (telar_gui_viewport){640, 360, 1}, &frame));
    pthread_mutex_lock(&mutex);
    while (!entered) {
        pthread_cond_wait(&condition, &mutex);
    }
    pthread_mutex_unlock(&mutex);
    telar_gui_frame replacement = {.token = 999};
    assert(!telar_frame_worker_submit(worker, (telar_gui_viewport){640, 360, 1}, &replacement));
    pthread_mutex_lock(&mutex);
    release_render = true;
    pthread_cond_broadcast(&condition);
    pthread_mutex_unlock(&mutex);
    struct pollfd fd = {telar_frame_worker_fd(worker), POLLIN, 0};
    assert(poll(&fd, 1, 1000) == 1);
    uint64_t token;
    enum telar_render_result result;
    assert(telar_frame_worker_take(worker, &token, &result));
    assert(token == 9 && result == TELAR_RENDER_DELIVERED);
    assert(!telar_frame_worker_take(worker, &token, &result));
    pthread_mutex_lock(&mutex);
    entered = release_render = false;
    pthread_mutex_unlock(&mutex);
    assert(telar_frame_worker_submit(worker, (telar_gui_viewport){640, 360, 1}, &frame));
    pthread_mutex_lock(&mutex);
    while (!entered) {
        pthread_cond_wait(&condition, &mutex);
    }
    pthread_mutex_unlock(&mutex);
    pthread_t closer;
    assert(pthread_create(&closer, NULL, close_worker, NULL) == 0);
    struct timespec delay = {0, 50000000};
    nanosleep(&delay, NULL);
    assert(!atomic_load(&destroyed));
    pthread_mutex_lock(&mutex);
    release_render = true;
    pthread_cond_broadcast(&condition);
    pthread_mutex_unlock(&mutex);
    pthread_join(closer, NULL);
    assert(atomic_load(&destroyed));
    return 0;
}
