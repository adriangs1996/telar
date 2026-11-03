#pragma once

#include <stdexcept>

namespace telar::runtime::cli {

// Zig's uncaught execution errors use this prefix; argument errors use the
// separate help-bearing diagnostic and machine edits have their own report.
class CommandError : public std::runtime_error {
public:
  using std::runtime_error::runtime_error;
};

}
