#pragma once

#include "../platform/file_descriptor.hpp"
#include "target.hpp"

namespace telar::runtime::redirect {

struct Connection {
  FileDescriptor child;
  FileDescriptor origin;
  Target target;
  FileDescriptor lifetime{};
};

}
