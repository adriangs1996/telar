#pragma once

#include "reply.hpp"
#include "graphics_payload.hpp"
#include "../../graphics/child_file.hpp"
#include "../../graphics/child_shared_memory.hpp"
#include "../../graphics/temporary_path.hpp"
#include "../../graphics/png_decoder.hpp"
#include "../../graphics/limits.hpp"
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
    std::array<std::optional<std::uint32_t>, 256> values;
    enum class Phase { key, ignored_key, value, ignored_value, data };
    Phase phase = Phase::key;
    std::uint8_t key = 0;
    std::array<char, 11> temporary;
    std::size_t length = 0;
    const auto finish = [&]() {
      auto value = std::string_view{temporary.data(), length};
      if (value.size() == 1 && (value.front() < '0' || value.front() > '9')) {
        values[key] = static_cast<std::uint8_t>(value.front());
      } else {
        if (value.starts_with('+')) {
          value.remove_prefix(1);
        }
        if ((key == 'z' || key == 'H' || key == 'V') && value.starts_with('-')) {
          const auto number = kittyUnsigned<std::uint32_t>(value.substr(1));
          if (!number || *number > std::uint32_t{INT32_MAX} + 1) {
            return false;
          }
          values[key] = 0u - *number;
        } else {
          const auto number = kittyUnsigned<std::uint32_t>(value);
          if (!number) {
            return false;
          }
          values[key] = *number;
        }
      }
      length = 0;
      return true;
    };
    const auto accumulate = [&](char byte, Phase overflow) {
      if (length == temporary.size()) {
        phase = overflow;
        length = 0;
      } else {
        temporary[length++] = byte;
      }
    };
    // Malformed keys suppress subsequent header fields until a payload
    // delimiter; previously completed fields remain part of the command.
    for (std::size_t offset = 0; offset < header.size() + (has_payload ? 1 : 0); ++offset) {
      const char byte = offset == header.size() ? ';' : header[offset];
      switch (phase) {
      case Phase::key:
        if (byte == '=') {
          phase = length == 1 ? Phase::value : Phase::ignored_value;
          if (length == 1) {
            key = static_cast<std::uint8_t>(temporary[0]);
          }
          length = 0;
        } else if (byte == ';') {
          phase = Phase::data;
        } else {
          accumulate(byte, Phase::ignored_key);
        }
        break;
      case Phase::ignored_key:
        if (byte == '=') {
          phase = Phase::ignored_value;
        }
        break;
      case Phase::value:
        if (byte == ',' || byte == ';') {
          if (!finish()) {
            return std::nullopt;
          }
          phase = byte == ',' ? Phase::key : Phase::data;
        } else {
          accumulate(byte, Phase::ignored_value);
        }
        break;
      case Phase::ignored_value:
        if (byte == ',') {
          phase = Phase::ignored_key;
        } else if (byte == ';') {
          phase = Phase::data;
        }
        break;
      case Phase::data:
        break;
      }
    }
    if (phase == Phase::key || phase == Phase::ignored_key || (phase == Phase::value && !finish())) {
      return std::nullopt;
    }
    const auto number = [&](char key, std::uint32_t fallback = 0) { return values[static_cast<std::uint8_t>(key)].value_or(fallback); };
    if (number('a') != 'q') {
      return std::nullopt;
    }
    result.image = number('i');
    result.number = number('I');
    result.placement = number('p');
    result.width = number('s');
    result.height = number('v');
    result.format = number('f', 32);
    if (result.format == 0) {
      result.format = 32;
    }
    result.quiet = number('q');
    result.offset = number('O');
    result.length = number('S');
    const auto medium = number('t', 'd');
    if (medium > UINT8_MAX || std::string_view{"dfst"}.find(static_cast<char>(medium)) == std::string_view::npos) {
      return std::nullopt;
    }
    result.medium = static_cast<char>(medium);
    if (values['o'] && *values['o'] != 'z') {
      return std::nullopt;
    }
    result.compressed = values['o'].has_value();
    return result;
  }
};

template <Allocator Memory>
class GraphicsQueries {
public:
  explicit GraphicsQueries(Memory &memory, GraphicsLimits limits = {})
      : memory_(memory, limits.pane_bytes), allocator_(memory_), decoded_(AllocatorRef<std::uint8_t, QueryMemory>{memory_}), inflated_(AllocatorRef<std::uint8_t, QueryMemory>{memory_}), image_limit_(limits.screenBytes()) {}

  void respond(std::string_view body, Reply<Memory> &reply) {
    const auto separator = body.find(';');
    const auto request = GraphicsQuery::parse(body.substr(1, separator == std::string_view::npos ? separator : separator - 1), separator != std::string_view::npos);
    if (!request || request->quiet > 1 || request->image == 0) {
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
    if (result == invalid_encoding || (request->quiet == 1 && result == "OK")) {
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
  using QueryMemory = BudgetAllocator<Memory>;
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
  QueryMemory memory_;
  GhosttyAllocatorBridge<QueryMemory> allocator_;
  Vector<std::uint8_t, QueryMemory> decoded_;
  Vector<std::uint8_t, QueryMemory> inflated_;
  std::size_t image_limit_;
};

}
