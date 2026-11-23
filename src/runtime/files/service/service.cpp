module telar.runtime.files.service;

import std;
import telar.runtime.transport.connection;
import telar.runtime.workers.background_executor;
import telar.wire.files;
import telar.wire.vocabulary;
import telar.base.memory.allocators;

namespace telar::runtime {

  namespace {

    // The operations of the largest ChangeFiles, decoded.
    constexpr std::size_t decode_bytes = std::size_t{16} * 1024;

  }

  FileService::FileService(ConcurrentMemory& memory)
      : directory_(memory),
        repository_(memory),
        changer_(memory),
        decode_(memory) {
    decode_.resize(decode_bytes);
  }

  void FileService::process(std::span<const Byte> payload, EncodedReply<ConcurrentMemory>& reply, const RequestContext& context) {
    static const std::atomic<bool> never{false};
    const auto& cancelled = context.cancelled == nullptr ? never : *context.cancelled;
    DecodeStorage storage{decode_.viewMut()};

    if (payload.empty()) {
      throw RequestError{FailureCode::invalid_request, "An empty request names no file"};
    }

    // The tag says which of the three takes the request.
    const auto tag = static_cast<ClientTag>(payload.front());

    if (tag == ClientTag::list_directory) {
      directory_.list(Codec::decode<ListDirectory>(payload, storage), reply);
    } else if (tag == ClientTag::measure_directory) {
      directory_.measure(Codec::decode<MeasureDirectory>(payload, storage), cancelled, reply);
    } else if (tag == ClientTag::query_changes) {
      repository_.changes(Codec::decode<QueryChanges>(payload, storage), cancelled, reply);
    } else if (tag == ClientTag::inspect_file) {
      repository_.inspect(Codec::decode<InspectFile>(payload, storage), cancelled, reply);
    } else if (tag == ClientTag::change_files) {
      changer_.change(Codec::decode<ChangeFiles>(payload, storage), cancelled, reply);
    } else if (tag == ClientTag::undo_file_changes) {
      changer_.undo(Codec::decode<UndoFileChanges>(payload, storage), reply);
    } else if (tag == ClientTag::commit_changes) {
      changer_.commit(Codec::decode<CommitChanges>(payload, storage), cancelled, reply);
    } else {
      throw RequestError{FailureCode::invalid_request, "Not a request on files"};
    }
  }

}
