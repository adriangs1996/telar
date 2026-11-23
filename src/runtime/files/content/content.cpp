module telar.runtime.files.content;

import std;
import telar.sys.posix;
import telar.platform.primitives;
import telar.runtime.files.entry;
import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

namespace telar::runtime {

  FileContent::FileContent(ConcurrentMemory& memory)
      : chunk_(memory),
        path_(memory) {}

  void FileContent::read(const ReadFile& request, EncodedReply<ConcurrentMemory>& reply) {
    if (!request.path.starts_with('/')) {
      throw RequestError{FailureCode::invalid_request, "A file is read by its absolute path"};
    }

    path_.assign(request.path);
    if (request.link) {
      readLink(request, reply);
      return;
    }

    // Without following a link, and without waiting on a pipe that took the file's name.
    const FileDescriptor file{::open(path_.data(), combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    struct stat status{};
    if (!file || ::fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode)) {
      throw RequestError{FailureCode::invalid_request, "The path is no file this account may read"};
    }

    // A file written since it was listed would arrive as part of one and part of another.
    if (!names(status, request.identity)) {
      throw RequestError{FailureCode::invalid_request, "The file changed since it was listed"};
    }

    const auto size = static_cast<std::uint64_t>(std::max<off_t>(0, status.st_size));
    if (request.offset > size) {
      throw RequestError{FailureCode::invalid_request, "The file ends before that offset"};
    }

    const auto wanted = std::min<std::uint64_t>({request.limit, FileLimits::chunk_bytes, size - request.offset});
    std::size_t held = 0;

    chunk_.resize(static_cast<std::size_t>(wanted));
    while (held < chunk_.size()) {
      const auto rest = chunk_.viewMut().subspan(held);
      const auto count = ::pread(file.get(), rest.data(), rest.size(), static_cast<off_t>(request.offset + held));
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        break;
      }

      held += static_cast<std::size_t>(count);
    }

    if (held < chunk_.size()) {
      throw RequestError{FailureCode::invalid_request, "The file was cut short while it was read"};
    }

    reply.send(FileChunk{
        .request_id = request.request_id,
        .offset = request.offset,
        .size = size,
        .end = request.offset + held >= size,
        .bytes = chunk_.view().first(held),
    });
  }

  void FileContent::readLink(const ReadFile& request, EncodedReply<ConcurrentMemory>& reply) {
    struct stat status{};
    if (::lstat(path_.data(), &status) != 0 || kindOf(status.st_mode) != FileKind::link) {
      throw RequestError{FailureCode::invalid_request, "The path is no link this account may read"};
    }

    if (!names(status, request.identity)) {
      throw RequestError{FailureCode::invalid_request, "The link changed since it was listed"};
    }

    chunk_.resize(FileLimits::path_bytes);

    const auto length = ::readlink(path_.data(), reinterpret_cast<char*>(chunk_.dataMut()), chunk_.size()); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): readlink writes the link's text as char, which may alias the bytes
    // One that fills the room may be longer than it: a text cut short is another link.
    if (length <= 0 || static_cast<std::size_t>(length) >= chunk_.size()) {
      throw RequestError{FailureCode::invalid_request, "The link says more than a path holds"};
    }

    const auto held = static_cast<std::size_t>(length);

    reply.send(FileChunk{
        .request_id = request.request_id,
        .offset = 0,
        .size = held,
        .end = true,
        .bytes = chunk_.view().first(held),
    });
  }

}
