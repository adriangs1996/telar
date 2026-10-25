#pragma once

#include "../suggestions/engine.hpp"
#include "request_context.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class SuggestionService {
public:
  explicit SuggestionService(Memory &memory, SuggestionOptions options)
      : engine_(memory, options) {}

  bool available() const noexcept {
    return engine_.available();
  }

  void process(std::span<const Byte> payload, EncodedReply<Memory> &reply, const RequestContext &context = {}) {
    std::array<Byte, 1024> scratch;
    DecodeStorage storage{scratch};
    const auto request = Codec::decode<SuggestCommand>(payload, storage);
    engine_.suggest(request, context.prompt, reply);
  }

  void idle() noexcept {
    engine_.idle();
  }

  void stop() noexcept {
    engine_.stop();
  }

private:
  SuggestionEngine<Memory> engine_;
};

}
