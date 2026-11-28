module telar.wire.execution;

import std;
import telar.wire.vocabulary;

namespace telar {

  void ExecutionRequest::validate() const {
    if ((execution_id == 0 && action != ExecutionAction::list) ||
        (!cwd.empty() && cwd.front() != '/')) {
      throw EncodingError{"Invalid execution request"};
    }

    if (action == ExecutionAction::start && (arguments.empty() || arguments.front().empty())) {
      throw EncodingError{"Missing execution arguments"};
    }

    std::size_t total = 0;

    for (const auto argument : arguments) {
      total = checkedWireSize(total, argument.size());
    }

    if (total > maximum_argument_bytes) {
      throw EncodingError{"Execution arguments too large"};
    }
  }

}
