#pragma once

// The macro alone: module units include it and import telar.platform.primitives,
// which exports the declarations its Debug expansion names.
// NOLINTBEGIN(cppcoreguidelines-macro-usage): a trace scope is a local the call site declares, named after its line, which only a macro can paste.
#if TELAR_DEBUG
#define TELAR_TRACE_PASTE(left, right) left##right
#define TELAR_TRACE_JOIN(left, right) TELAR_TRACE_PASTE(left, right)
#define TELAR_TRACE(name)                                                         \
  const ::telar::runtime::trace::Scope TELAR_TRACE_JOIN(telar_trace_, __LINE__) { \
    ::telar::runtime::trace::literal(name)                                        \
  }
#else
#define TELAR_TRACE(name) static_cast<void>(0)
#endif
// NOLINTEND(cppcoreguidelines-macro-usage)
