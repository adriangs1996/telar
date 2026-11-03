#pragma once

#include "target.hpp"
#include "telar_platform/file_descriptor.hpp"

namespace telar::runtime::redirect {

struct Connection {
  FileDescriptor child;
  FileDescriptor origin;
  Target target;
  FileDescriptor lifetime{};
};

}
