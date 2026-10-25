#pragma once

#include "../editors/remote_editor.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class EditorService {
public:
  explicit EditorService(Memory &memory)
      : editor_(memory) {}

  void process(std::span<const Byte> payload, EncodedReply<Memory> &reply, const RequestContext &context = {}) {
    std::array<Byte, 1024> scratch;
    DecodeStorage storage{scratch};
    editor_.open(Codec::decode<OpenEditor>(payload, storage), context, reply);
  }

private:
  RemoteEditor<Memory> editor_;
};

}
