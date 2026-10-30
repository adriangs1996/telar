#pragma once

#include "reply.hpp"
#include "graphics_payload.hpp"
#include "graphics_header.hpp"
#include "../../graphics/child_file.hpp"
#include "../../graphics/child_shared_memory.hpp"
#include "../../graphics/temporary_path.hpp"
#include "../../graphics/png_decoder.hpp"
#include "../../graphics/limits.hpp"
#include "../../graphics/query_resources.hpp"
#include "../../graphics/media_budget.hpp"
#include "../ghostty_allocator.hpp"
#include <zlib.h>

namespace telar::runtime::control {

struct GraphicsQuery {
  std::uint32_t image = 0;
  std::uint32_t number = 0;
  std::uint32_t placement = 0;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t format = 32;
  std::uint32_t quiet = 0;
  std::uint32_t offset = 0;
  std::uint32_t length = 0;
  char medium = 'd';
  bool compressed = false;

  static std::optional<GraphicsQuery> parse(std::string_view header, bool has_payload) noexcept {
    GraphicsQuery result;
    std::array<std::optional<std::uint32_t>, static_cast<std::size_t>(Field::ignored)> values;
    const bool valid = GraphicsHeader::scan(header, has_payload, [&](std::uint8_t key, std::string_view text) noexcept {
      const auto value = GraphicsHeader::value(key, text);
      if (!value) {
        return false;
      }
      const auto field = parameterField(key);
      if (field != Field::ignored) {
        values[static_cast<std::size_t>(field)] = *value;
      }
      return true;
    });
    if (!valid) {
      return std::nullopt;
    }
    const auto number = [&](Field field, std::uint32_t fallback = 0) { return values[static_cast<std::size_t>(field)].value_or(fallback); };
    if (number(Field::action) != 'q') {
      return std::nullopt;
    }
    result.image = number(Field::image);
    result.number = number(Field::number);
    result.placement = number(Field::placement);
    result.width = number(Field::width);
    result.height = number(Field::height);
    result.format = number(Field::format, 32);
    if (result.format == 0) {
      result.format = 32;
    }
    result.quiet = number(Field::quiet);
    result.offset = number(Field::offset);
    result.length = number(Field::length);
    const auto medium = number(Field::medium, 'd');
    if (medium > UINT8_MAX || std::string_view{"dfst"}.find(static_cast<char>(medium)) == std::string_view::npos) {
      return std::nullopt;
    }
    result.medium = static_cast<char>(medium);
    const auto compression = values[static_cast<std::size_t>(Field::compression)];
    if (compression && *compression != 'z') {
      return std::nullopt;
    }
    result.compressed = compression.has_value();
    return result;
  }

private:
  enum class Field { action, image, number, placement, width, height, format, quiet, offset, length, medium, compression, ignored };

  static constexpr Field parameterField(std::uint8_t key) noexcept {
    switch (key) {
    case 'a': return Field::action;
    case 'i': return Field::image;
    case 'I': return Field::number;
    case 'p': return Field::placement;
    case 's': return Field::width;
    case 'v': return Field::height;
    case 'f': return Field::format;
    case 'q': return Field::quiet;
    case 'O': return Field::offset;
    case 'S': return Field::length;
    case 't': return Field::medium;
    case 'o': return Field::compression;
    default: return Field::ignored;
    }
  }
};

template <Allocator Memory>
class GraphicsQueries {
public:
  explicit GraphicsQueries(Memory &memory, GraphicsQueryResources resources = {})
      : local_budget_(resources.limits.global_bytes), memory_(memory, resources.budget != nullptr ? *resources.budget : local_budget_, resources.limits.pane_bytes, resources.budget != nullptr ? resources.usage : nullptr), allocator_(memory_), decoded_(AllocatorRef<std::uint8_t, QueryMemory>{memory_}), inflated_(AllocatorRef<std::uint8_t, QueryMemory>{memory_}), image_limit_(std::min(resources.limits.screenBytes(), resources.limits.global_bytes)) {}

  void discard() noexcept {
    Vector<std::uint8_t, QueryMemory>{decoded_.get_allocator()}.swap(decoded_);
    Vector<std::uint8_t, QueryMemory>{inflated_.get_allocator()}.swap(inflated_);
  }

  void respond(std::string_view body, Reply<Memory> &reply) {
    if (image_limit_ == 0) {
      return;
    }
    const auto separator = body.find(';');
    const auto request = GraphicsQuery::parse(body.substr(1, separator == std::string_view::npos ? separator : separator - 1), separator != std::string_view::npos);
    if (!request || request->image == 0) {
      return;
    }

    const auto payload = separator == std::string_view::npos ? std::string_view{} : body.substr(separator + 1);
    if (payload.size() > maximum_encoded_bytes) {
      return;
    }
    std::string_view result;
    try {
      decoded_.resize(payload.size() / 4 * 3 + (payload.size() % 4 == 0 ? 0 : 3));
      const auto decoded_size = decodeGraphicsPayload(payload, decoded_);
      if (!decoded_size) {
        return;
      }
      decoded_.resize(*decoded_size);
      result = request->number != 0 ? "EINVAL: image ID and number are mutually exclusive" : validate(*request);
    } catch (const std::bad_alloc &) {
      result = "ENOMEM: out of memory";
    } catch (const std::length_error &) {
      result = "ENOMEM: out of memory";
    }
    if (result == invalid_encoding || request->quiet > 1 || (request->quiet == 1 && result == "OK")) {
      return;
    }

    reply.append("\x1b_Gi=");
    reply.number(request->image);
    if (request->number != 0) {
      reply.append(",I=");
      reply.number(request->number);
    }
    if (request->placement != 0) {
      reply.append(",p=");
      reply.number(request->placement);
    }
    reply.append(";");
    reply.append(result);
    reply.append("\x1b\\");
  }

private:
  std::string_view validate(const GraphicsQuery &request) {
    if (request.format != 24 && request.format != 32 && request.format != 100) {
      return "EINVAL: unsupported format";
    }
    if (request.format != 100 && (request.width > maximum_dimension || request.height > maximum_dimension)) {
      return "EINVAL: dimensions too large";
    }
    if (request.medium != 'd') {
      std::optional<GraphicsChildFile> file;
      std::array<std::uint8_t, PATH_MAX + 1> name;
      if (request.medium == 'f' || request.medium == 't') {
        file = GraphicsChildFile::openDecoded(decoded_);
      } else {
        auto descriptor = GraphicsChildSharedMemory::openDecoded(decoded_, name);
        struct stat metadata{};
        if (descriptor && ::fstat(descriptor.get(), &metadata) == 0 && metadata.st_uid == ::getuid() && metadata.st_size > 0) {
          file = GraphicsChildFile{std::move(descriptor), static_cast<std::uint64_t>(metadata.st_size)};
        }
      }
      if (!file || request.offset > file->size) {
        return "EINVAL: invalid data";
      }
      GraphicsTemporaryPath temporary{*file};
      if (request.medium == 't') {
        if (const auto error = temporary.authorize(); !error.empty()) {
          return error;
        }
      }
      struct SharedCleanup {
        const char *name;
        ~SharedCleanup() {
          if (name != nullptr) {
            ::shm_unlink(name);
          }
        }
      } shared{request.medium == 's' ? reinterpret_cast<const char *>(name.data()) : nullptr};
      auto count = request.length != 0 ? request.length : file->size - request.offset;
      if (request.medium == 's' && request.length == 0 && !request.compressed && request.format != 100) {
        count = static_cast<std::uint64_t>(request.width) * request.height * (request.format == 24 ? 3 : 4);
      }
      if (count > image_limit_ || count > file->size - request.offset) {
        return "EINVAL: invalid data";
      }
      decoded_.resize(static_cast<std::size_t>(count));
      const bool read = request.medium == 's' ? GraphicsChildSharedMemory::read(file->descriptor.get(), decoded_, request.offset) : file->read(decoded_, request.offset);
      if (!read) {
        return "EINVAL: invalid data";
      }
    }

    std::span<const std::uint8_t> data = decoded_;
    if (request.compressed) {
      z_stream stream{};
      stream.opaque = &memory_;
      stream.zalloc = &allocateInflate;
      stream.zfree = &freeInflate;
      if (::inflateInit(&stream) != Z_OK) {
        return "EINVAL: decompression failed";
      }
      struct Inflater {
        z_stream &stream;
        ~Inflater() { ::inflateEnd(&stream); }
      } owner{stream};
      stream.next_in = const_cast<Bytef *>(data.data());
      stream.avail_in = static_cast<uInt>(data.size());
      inflated_.clear();
      int status = Z_OK;
      while (status == Z_OK) {
        if (inflated_.size() == image_limit_) {
          return "EINVAL: dimensions too large";
        }
        const auto start = inflated_.size();
        inflated_.resize(std::min(image_limit_, start + inflate_chunk_bytes));
        stream.next_out = inflated_.data() + start;
        stream.avail_out = static_cast<uInt>(inflated_.size() - start);
        status = ::inflate(&stream, Z_NO_FLUSH);
        inflated_.resize(inflated_.size() - stream.avail_out);
      }
      if (status != Z_STREAM_END) {
        return "EINVAL: decompression failed";
      }
      data = inflated_;
    }

    if (request.format == 100) {
      GhosttySysImage image{};
      if (!decodePngImage(allocator_.get(), data, image, image_limit_)) {
        return "EINVAL: invalid data";
      }
      ghostty_free(allocator_.get(), image.data, image.data_len);
      return image.width > maximum_dimension || image.height > maximum_dimension ? "EINVAL: dimensions too large" : "OK";
    }
    if (request.width == 0 || request.height == 0) {
      return "EINVAL: dimensions required";
    }
    if (request.width > maximum_dimension || request.height > maximum_dimension) {
      return "EINVAL: dimensions too large";
    }
    const auto bytes = static_cast<std::uint64_t>(request.width) * request.height * (request.format == 24 ? 3 : 4);
    if (bytes > image_limit_) {
      return "EINVAL: dimensions too large";
    }
    return data.size() != bytes ? "EINVAL: invalid data" : "OK";
  }

public:
  static constexpr std::string_view invalid_encoding = "invalid-base64";

private:
  using QueryMemory = MediaAllocator<Memory>;
  struct alignas(std::max_align_t) InflateAllocation {
    std::size_t bytes;
  };

  static void *allocateInflate(void *context, unsigned count, unsigned size) noexcept {
    if (size != 0 && count > (SIZE_MAX - sizeof(InflateAllocation)) / size) {
      return nullptr;
    }
    const auto bytes = static_cast<std::size_t>(count) * size + sizeof(InflateAllocation);
    auto *allocation = static_cast<InflateAllocation *>(static_cast<QueryMemory *>(context)->allocate(bytes, alignof(InflateAllocation)));
    if (allocation == nullptr) {
      return nullptr;
    }
    allocation->bytes = bytes;
    return allocation + 1;
  }

  static void freeInflate(void *context, void *pointer) noexcept {
    if (pointer != nullptr) {
      auto *allocation = static_cast<InflateAllocation *>(pointer) - 1;
      static_cast<QueryMemory *>(context)->deallocate(allocation, allocation->bytes, alignof(InflateAllocation));
    }
  }

  static constexpr std::size_t maximum_encoded_bytes = 65 * 1024 * 1024;
  static constexpr std::size_t inflate_chunk_bytes = 64 * 1024;
  static constexpr unsigned maximum_dimension = 10000;
  MediaBudget local_budget_;
  QueryMemory memory_;
  GhosttyAllocatorBridge<QueryMemory> allocator_;
  Vector<std::uint8_t, QueryMemory> decoded_;
  Vector<std::uint8_t, QueryMemory> inflated_;
  std::size_t image_limit_;
};

}
