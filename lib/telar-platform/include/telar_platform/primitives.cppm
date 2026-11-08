module;
#include "telar_platform/graphics/child_shared_memory.hpp"
#include "telar_platform/mapped_region.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/trace.hpp"

export module telar.platform.primitives;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime {
using telar::runtime::FileDescriptor;
using telar::runtime::GraphicsChildSharedMemory;
using telar::runtime::MappedRegion;
using telar::runtime::copyGraphicsName;
using telar::runtime::decodeGraphicsName;
using telar::runtime::duplicateCloseOnExec;
using telar::runtime::randomBytes;
using telar::runtime::setCloseOnExec;
using telar::runtime::setNonblocking;
}
#if TELAR_DEBUG
export namespace telar::runtime::trace {
using telar::runtime::trace::Record;
using telar::runtime::trace::Scope;
using telar::runtime::trace::Session;
using telar::runtime::trace::buffer_capacity;
using telar::runtime::trace::close;
using telar::runtime::trace::literal;
using telar::runtime::trace::now;
using telar::runtime::trace::open;
using telar::runtime::trace::record;
}
#endif

