#pragma once

#include "../../graphics/child_file.hpp"
#include "../../graphics/media_budget.hpp"
#include "../../graphics/png_decoder.hpp"
#include "../../graphics/query_resources.hpp"
#include "../../graphics/temporary_path.hpp"
#include "../ghostty_allocator.hpp"
#include "graphics_header.hpp"
#include "graphics_payload.hpp"
#include "reply.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <cassert>
#include <charconv>
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
    bool query = false;
    return parse(header, has_payload, query);
  }

  // Recognition survives invalid non-action fields, so malformed native
  // queries remain intercepted without a second scan or foreign response.
  static std::optional<GraphicsQuery> parse(std::string_view header, bool has_payload, bool &query) noexcept {
    query = false;
    bool values_valid = true;
    GraphicsQuery result;
    std::array<std::optional<std::uint32_t>, static_cast<std::size_t>(Field::ignored)> values;
    const bool valid = GraphicsHeader::scan(header, has_payload, [&](std::uint8_t key, std::string_view text) noexcept {
      const auto value = GraphicsHeader::value(key, text);
      if (key == 'a') {
        query = value == static_cast<std::uint32_t>('q');
      }
      if (!value) {
        values_valid = false;
        return true;
      }
      const auto field = parameterField(key);
      if (field != Field::ignored) {
        values[static_cast<std::size_t>(field)] = *value;
      }
      return true;
    });
    if (!valid || !values_valid) {
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

  bool handle(std::string_view body, Reply<Memory> &reply, bool enabled) {
    const auto separator = body.find(';');
    bool query = false;
    const auto request = GraphicsQuery::parse(body.substr(1, separator == std::string_view::npos ? separator : separator - 1), separator != std::string_view::npos, query);
    if (!query) {
      return false;
    }
    if (!enabled || image_limit_ == 0 || !request || request->image == 0) {
      return true;
    }

    const auto payload = separator == std::string_view::npos ? std::string_view{} : body.substr(separator + 1);
    if (payload.size() > maximum_encoded_bytes) {
      return true;
    }
    std::string_view result;
    try {
      decoded_.resize(payload.size() / 4 * 3 + (payload.size() % 4 == 0 ? 0 : 3));
      const auto decoded_size = decodeGraphicsPayload(payload, decoded_);
      if (!decoded_size) {
        return true;
      }
      decoded_.resize(*decoded_size);
      result = request->number != 0 ? "EINVAL: image ID and number are mutually exclusive" : validate(*request);
    } catch (const std::bad_alloc &) {
      result = "ENOMEM: out of memory";
    } catch (const std::length_error &) {
      result = "ENOMEM: out of memory";
    }
    if (result == invalid_encoding || request->quiet > 1 || (request->quiet == 1 && result == "OK")) {
      return true;
    }

    encodeReply(*request, result, reply);
    return true;
  }

private:
  static void encodeReply(const GraphicsQuery &request, std::string_view result, Reply<Memory> &reply) {
    constexpr std::size_t maximum_reply_bytes = 128;
    constexpr std::size_t identifier_digits = std::numeric_limits<std::uint32_t>::digits10 + 1;
    constexpr std::string_view image_prefix = "\x1b_Gi=";
    constexpr std::string_view number_prefix = ",I=";
    constexpr std::string_view placement_prefix = ",p=";
    constexpr std::size_t maximum_prefix_bytes = image_prefix.size() + number_prefix.size() + placement_prefix.size() + 3 * identifier_digits + 1;
    constexpr std::string_view terminator = "\x1b\\";
    static_assert(maximum_reply_bytes > maximum_prefix_bytes + terminator.size());
    std::array<char, maximum_reply_bytes> encoded;
    auto *next = std::copy(image_prefix.begin(), image_prefix.end(), encoded.data());
    const auto identifier = [&](std::uint32_t value) {
      const auto formatted = std::to_chars(next, encoded.data() + maximum_prefix_bytes, value);
      assert(formatted.ec == std::errc{});
      next = formatted.ptr;
    };
    identifier(request.image);
    if (request.number != 0) {
      next = std::copy(number_prefix.begin(), number_prefix.end(), next);
      identifier(request.number);
    }
    if (request.placement != 0) {
      next = std::copy(placement_prefix.begin(), placement_prefix.end(), next);
      identifier(request.placement);
    }
    *next++ = ';';

    // Result strings are internal diagnostics. Keep the bound explicit if a
    // future validator adds a longer message; only initialized bytes escape.
    if (result.size() > static_cast<std::size_t>(encoded.data() + encoded.size() - next) - terminator.size()) {
      throw std::length_error{"Graphics query reply exceeds its configured limit"};
    }
    next = std::copy(result.begin(), result.end(), next);
    next = std::copy(terminator.begin(), terminator.end(), next);
    reply.append({encoded.data(), static_cast<std::size_t>(next - encoded.data())});
  }

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
