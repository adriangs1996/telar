#include "frame_worker.h"
#include <pthread.h>
#include <stdlib.h>

struct telar_frame_worker {
    telar_renderer *renderer;
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int wake[2];
    bool stopping, pending, active, done;
    enum telar_render_result result;
    telar_gui_viewport viewport;
    telar_gui_frame frame;
};
static void *run(void *context) {
    telar_frame_worker *self = context;
    pthread_mutex_lock(&self->mutex);
    for (;;) {
        while (!self->pending && !self->stopping) {
            pthread_cond_wait(&self->condition, &self->mutex);
        }
        if (self->stopping) {
            break;
        }
        telar_gui_viewport viewport = self->viewport;
        telar_gui_frame frame = self->frame;
        self->pending = false;
        pthread_mutex_unlock(&self->mutex);
        enum telar_render_result result = telar_renderer_draw(self->renderer, viewport, &frame);
        pthread_mutex_lock(&self->mutex);
        self->result = result;
        self->done = true;
        telar_gui_wake(self->wake[1]);
    }
    pthread_mutex_unlock(&self->mutex);
    return NULL;
}
telar_frame_worker *telar_frame_worker_create(telar_renderer *renderer) {
    telar_frame_worker *self = calloc(1, sizeof *self);
    if (self == NULL) {
        return NULL;
    }
    self->renderer = renderer;
    if (telar_gui_pipe(self->wake) != 0) {
        free(self);
        return NULL;
    }
    if (pthread_mutex_init(&self->mutex, NULL) != 0) {
        goto fail_pipe;
    }
    if (pthread_cond_init(&self->condition, NULL) != 0) {
        goto fail_mutex;
    }
    if (pthread_create(&self->thread, NULL, run, self) != 0) {
        goto fail_condition;
    }
    return self;
fail_condition:
    pthread_cond_destroy(&self->condition);
fail_mutex:
    pthread_mutex_destroy(&self->mutex);
fail_pipe:
    telar_gui_close_pipe(self->wake);
    free(self);
    return NULL;
}
int telar_frame_worker_fd(telar_frame_worker *self) { return self->wake[0]; }
bool telar_frame_worker_submit(telar_frame_worker *self, telar_gui_viewport viewport, const telar_gui_frame *frame) {
    pthread_mutex_lock(&self->mutex);
    if (self->active || self->stopping) {
        pthread_mutex_unlock(&self->mutex);
        return false;
    }
    self->active = true;
    self->viewport = viewport;
    self->frame = *frame;
    self->pending = true;
    pthread_cond_signal(&self->condition);
    pthread_mutex_unlock(&self->mutex);
    return true;
}
bool telar_frame_worker_take(telar_frame_worker *self, uint64_t *token, enum telar_render_result *result) {
    telar_gui_drain(self->wake[0]);
    pthread_mutex_lock(&self->mutex);
    bool done = self->done;
    if (done) {
        *token = self->frame.token;
        *result = self->result;
        self->done = false;
        self->active = false;
    }
    pthread_mutex_unlock(&self->mutex);
    return done;
}
void telar_frame_worker_destroy(telar_frame_worker *self) {
    if (self == NULL) {
        return;
    }
    pthread_mutex_lock(&self->mutex);
    self->stopping = true;
    pthread_cond_signal(&self->condition);
    pthread_mutex_unlock(&self->mutex);
    pthread_join(self->thread, NULL);
    pthread_cond_destroy(&self->condition);
    pthread_mutex_destroy(&self->mutex);
    telar_gui_close_pipe(self->wake);
    free(self);
}
