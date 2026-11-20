module telar.runtime.workers.background_executor;
import telar.base.ds;

namespace telar::runtime {

  SuggestionService::SuggestionService(ConcurrentMemory& memory, SuggestionOptions options)
      : engine_(memory, options) {}

  bool SuggestionService::available() const noexcept {
    return engine_.available();
  }

  void SuggestionService::process(std::span<const Byte> payload, EncodedReply<ConcurrentMemory>& reply, const RequestContext& context) {
    // A suggestion request decodes a prompt and a few short fields.
    constexpr std::size_t decode_bytes = 1024;
    ds::Array<Byte, decode_bytes> scratch; // NOLINT(cppcoreguidelines-pro-type-member-init): the decoder writes the bytes it hands out before they are read, so zeroing them would cost every suggestion request
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
