#pragma once

#include "clone.hpp"
#include "clone_origin.hpp"
#include "file_store.hpp"
#include "options.hpp"

namespace telar::runtime::checkpoint {

template <Allocator Memory>
void prepareClone(Memory &memory, const CloneOptions &options, std::string_view destination, std::string_view socket) {
  if (options.source_checkpoint.empty()) {
    return;
  }
  for (const auto path : {options.source_checkpoint, options.source_socket, destination}) {
    if (path.empty() || path.front() != '/' || path.contains('\0')) {
      throw EncodingError{"Cloning requires absolute source and destination paths"};
    }
  }
  if (options.source_socket == socket || options.source_checkpoint == destination) {
    throw EncodingError{"Cannot clone a runtime onto itself"};
  }

  createPrivateDirectory(destination.substr(0, destination.rfind('/')));
  FileStore checkpoint{memory, destination};
  const auto held = checkpoint.lock();
  String<Memory> origin_path{socket, AllocatorRef<char, Memory>{memory}};
  origin_path += ".desktop-clone.json";
  FileStore origin{memory, origin_path};
  Vector<Byte, Memory> source{AllocatorRef<Byte, Memory>{memory}};
  if (checkpoint.load(source)) {
    if (!origin.load(source)) {
      throw EncodingError{"Clone destination already exists without an origin"};
    }
    if (!matchingCloneOrigin(memory, source, options.source_socket)) {
      throw EncodingError{"Clone destination has a different origin"};
    }
    return;
  }
  if (!readPrivateFile(AT_FDCWD, options.source_checkpoint, source, maximum_bytes)) {
    throw EncodingError{"Clone source checkpoint is missing"};
  }

  Vector<Byte, Memory> output{AllocatorRef<Byte, Memory>{memory}};
  output.resize(maximum_bytes);
  const auto copied = clone(source, output, options.shell);
  const auto manifest = encodeCloneOrigin(memory, copied, options.source_socket);
  const auto marker = std::span<const Byte>{reinterpret_cast<const Byte *>(manifest.data()), manifest.size()};
  if (const auto error = origin.observe(marker)) {
    throw SystemError{"Write clone origin", error};
  }
  if (const auto error = checkpoint.observe(copied)) {
    throw SystemError{"Write cloned checkpoint", error};
  }
}

}
