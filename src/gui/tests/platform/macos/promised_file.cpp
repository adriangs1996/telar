#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "platform/promised_file.hpp"
#include "platform/macos/promised_file_bridge.h"
#include <cstddef>
#include <memory>
#include <string>

namespace telar::gui::test {
  namespace {

    struct PromiseAnswerContext {
      std::shared_ptr<PromiseAnswer> answer;
    };

    void completePromise(void* context, const char* failure_utf8) {
      const std::unique_ptr<PromiseAnswerContext> owned{static_cast<PromiseAnswerContext*>(context)};

      owned->answer->answered = true;
      owned->answer->failure = failure_utf8 == nullptr ? std::string{} : std::string{failure_utf8};
    }

  }

  std::string promisedName(const platform::FileDrag& drag, std::size_t row) {
    const char* const name = telarTestPromisedName(drag.nativeWriters(), row);

    return name == nullptr ? std::string{} : std::string{name};
  }

  bool askPromisedFile(const platform::FileDrag& drag, std::size_t row, const std::string& path, const std::shared_ptr<PromiseAnswer>& answer) {
    auto holder = std::make_unique<PromiseAnswerContext>(PromiseAnswerContext{.answer = answer});
    if (!telarTestAskPromisedFile(drag.nativeWriters(), row, path.c_str(), &completePromise, holder.get())) {
      return false;
    }

    static_cast<void>(holder.release());
    return true;
  }

}
