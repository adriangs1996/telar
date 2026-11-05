cmake_minimum_required(VERSION 3.24)
project(telar_sqlite LANGUAGES C)

# History search uses FTS5. Nothing loads SQLite extensions, so that code is
# left out, as the Zig build does.
add_library(sqlite3 STATIC sqlite3.c)
target_compile_definitions(sqlite3 PRIVATE SQLITE_ENABLE_FTS5 SQLITE_OMIT_LOAD_EXTENSION)
install(TARGETS sqlite3 ARCHIVE DESTINATION lib)
install(FILES sqlite3.h sqlite3ext.h DESTINATION include)
