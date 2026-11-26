#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TelarGuiFileDrag TelarGuiFileDrag;

typedef struct TelarGuiDraggedOut {
  const char* text_data;
  size_t text_size;
  const char* path_data;
  size_t path_size;
  const char* promised_data;
  size_t promised_size;
  uint32_t row;
  bool directory;
} TelarGuiDraggedOut;

typedef void (*TelarGuiPromiseAskedCallback)(
    void* context,
    uint32_t row,
    uint64_t ticket,
    const char* directory_data,
    size_t directory_size,
    const char* name_data,
    size_t name_size
);

#ifdef __cplusplus
[[tbc::raw]]
#endif
TelarGuiFileDrag* telarGuiFileDragCreate(void);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void telarGuiFileDragDestroy(TelarGuiFileDrag* self);

#ifdef __cplusplus
[[tbc::raw]]
#endif
bool telarGuiFileDragGive(
    TelarGuiFileDrag* self,
    void* ns_view,
    const TelarGuiDraggedOut* rows,
    size_t row_count,
    TelarGuiPromiseAskedCallback callback,
    void* context
);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void telarGuiFileDragEnd(TelarGuiFileDrag* self, uint64_t ticket, const char* failure_data, size_t failure_size);

#ifdef __cplusplus
[[tbc::raw]]
#endif
const void* telarGuiFileDragWriters(const TelarGuiFileDrag* self);

#ifdef __cplusplus
}
#endif
