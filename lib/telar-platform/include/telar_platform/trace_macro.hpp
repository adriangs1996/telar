#pragma once

// The macro alone: module units include it and import telar.platform.primitives,
// which exports the declarations its Debug expansion names.
#if TELAR_DEBUG
#define TELAR_TRACE_JOIN_(left, right) left##right
#define TELAR_TRACE_JOIN(left, right) TELAR_TRACE_JOIN_(left, right)
#define TELAR_TRACE(name)                                                         \
  const ::telar::runtime::trace::Scope TELAR_TRACE_JOIN(telar_trace_, __LINE__) { \
    ::telar::runtime::trace::literal(name)                                        \
  }
#else
#define TELAR_TRACE(name) static_cast<void>(0)
#endif
