export module telar.runtime.files.content;

import std;
import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

export namespace telar::runtime {

  // The bytes of a file of this machine, a chunk at a time, for a window that takes them to
  // another machine. Each chunk is read from the file its listing named, or not at all.
  class FileContent {
  public:
    explicit FileContent(ConcurrentMemory& memory);

    // Sends the FileChunk at `request.offset`. Throws RequestError for a path that is not
    // absolute, what is no regular file or is reached through a link, a file that is no longer
    // the one `request.identity` names, and an offset past its end.
    void read(const ReadFile& request, EncodedReply<ConcurrentMemory>& reply);

  private:
    // The chunk being read, kept from one request to the next.
    ds::Vec<Byte, ConcurrentMemory> chunk_;
    ds::String<ConcurrentMemory> path_;
  };

}
