module telar.runtime.platform.background_executor;
import telar.base.ds;

namespace telar::runtime {

  SuggestionService::SuggestionService(ConcurrentMemory& memory, SuggestionOptions options)
      : engine_(memory, options) {}

  bool SuggestionService::available() const noexcept {
    return engine_.available();
  }

  void SuggestionService::process(std::span<const Byte> payload, EncodedReply<ConcurrentMemory>& reply, const RequestContext& context) {
    ds::Array<Byte, 1024> scratch;
    DecodeStorage storage{scratch.viewMut()};
    const auto request = Codec::decode<SuggestCommand>(payload, storage);

    engine_.suggest(request, context.prompt, reply);
  }

  void SuggestionService::idle() noexcept {
    engine_.idle();
  }

  void SuggestionService::stop() noexcept {
    engine_.stop();
  }

}
