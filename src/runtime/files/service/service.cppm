export module telar.runtime.files.service;

import std;

import telar.runtime.files.directory;
import telar.runtime.files.operations;
import telar.runtime.files.repository;
import telar.runtime.transport.connection;
import telar.runtime.workers.background_executor;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

export namespace telar::runtime {

  // The explorer's requests on the files of this machine, answered on one worker's thread: a
  // listing waits for no text search, and a directory that takes long to read holds no pane back.
  class FileService {
  public:
    explicit FileService(ConcurrentMemory& memory);

    // Answers the request `payload` encodes: a listing, a measure, a repository's changes, a
    // preview, or a change to the files.
    void process(std::span<const Byte> payload, EncodedReply<ConcurrentMemory>& reply, const RequestContext& context = {});

  private:
    DirectoryReader directory_;
    RepositoryReader repository_;
    FileChanger changer_;
    // Where a request's operations are decoded.
    ds::Vec<Byte, ConcurrentMemory> decode_;
  };

}
