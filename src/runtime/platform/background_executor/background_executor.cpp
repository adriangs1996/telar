module telar.runtime.platform.background_executor;

namespace telar::runtime {

  template <ConcurrentAllocator Memory>
  SuggestionService<Memory>::SuggestionService(Memory& memory, SuggestionOptions options)
      : engine_(memory, options) {}

  template <ConcurrentAllocator Memory>
  bool SuggestionService<Memory>::available() const noexcept {
    return engine_.available();
  }

  template <ConcurrentAllocator Memory>
  void SuggestionService<Memory>::process(std::span<const Byte> payload, EncodedReply<Memory>& reply, const RequestContext& context) {
    std::array<Byte, 1024> scratch;
    DecodeStorage storage{scratch};
    const auto request = Codec::decode<SuggestCommand>(payload, storage);

    engine_.suggest(request, context.prompt, reply);
  }

  template <ConcurrentAllocator Memory>
  void SuggestionService<Memory>::idle() noexcept {
    engine_.idle();
  }

  template <ConcurrentAllocator Memory>
  void SuggestionService<Memory>::stop() noexcept {
    engine_.stop();
  }

  template class SuggestionService<ConcurrentMemory>;

}
