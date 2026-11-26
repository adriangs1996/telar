#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TelarTestDragAnswer {
  int answers;
  bool failed;
  char failure[128];
} TelarTestDragAnswer;

#ifdef __cplusplus
[[tbc::raw]]
#endif
size_t telarTestDragWriterCount(const void* writers);

#ifdef __cplusplus
[[tbc::raw]]
#endif
bool telarTestDragVerifyInitialWriters(const void* writers);

#ifdef __cplusplus
[[tbc::raw]]
#endif
bool telarTestDragAskUrl(const void* writers, size_t index, const char* url_utf8, bool is_file_url, bool is_directory, TelarTestDragAnswer* answer);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void* telarTestDragRetainPromise(const void* writers, size_t index);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void telarTestDragAskRetainedPromise(void* promise_handle, const char* path_utf8, TelarTestDragAnswer* answer);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void telarTestDragReleasePromise(void* promise_handle);

#ifdef __cplusplus
}
#endif
