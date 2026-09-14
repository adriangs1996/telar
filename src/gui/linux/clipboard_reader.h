#ifndef TELAR_CLIPBOARD_READER_H
#define TELAR_CLIPBOARD_READER_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "clipboard.h"

enum telar_clipboard_read_status {
    TELAR_CLIPBOARD_READ_OK,
    TELAR_CLIPBOARD_READ_FAILED,
    TELAR_CLIPBOARD_READ_TOO_LARGE,
    TELAR_CLIPBOARD_READ_CANCELLED,
};

// One reader owns its descriptor and retains the complete result until the
// window thread has admitted the corresponding event to Zig's input queue.
typedef struct {
    int fd;
    bool pending, ready;
    uint64_t request_id;
    int64_t deadline_ms;
    enum telar_clipboard_read_status status;
    size_t len;
    uint8_t bytes[TELAR_CLIPBOARD_LIMIT];
} telar_clipboard_reader;

void telar_clipboard_reader_init(telar_clipboard_reader *);
bool telar_clipboard_reader_begin(telar_clipboard_reader *, int fd, uint64_t request_id, int64_t now_ms);
void telar_clipboard_reader_dispatch(telar_clipboard_reader *, int64_t now_ms);
void telar_clipboard_reader_cancel(telar_clipboard_reader *);
void telar_clipboard_reader_release(telar_clipboard_reader *);
int telar_clipboard_reader_timeout(const telar_clipboard_reader *, int64_t now_ms);
#endif
