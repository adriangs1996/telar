#ifndef TELAR_FRAME_WORKER_H
#define TELAR_FRAME_WORKER_H
#include "renderer.h"
typedef struct telar_frame_worker telar_frame_worker;
telar_frame_worker *telar_frame_worker_create(telar_renderer *renderer);
int telar_frame_worker_fd(telar_frame_worker *);
void telar_frame_worker_submit(telar_frame_worker *, telar_gui_viewport viewport, const telar_gui_frame *frame);
bool telar_frame_worker_take(telar_frame_worker *, uint64_t *token, enum telar_render_result *result);
void telar_frame_worker_destroy(telar_frame_worker *);
#endif
