#pragma once

#include "reply.hpp"
#include "../../graphics/child_file.hpp"
#include "../../graphics/child_shared_memory.hpp"
#include "../../graphics/png_decoder.hpp"
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

  static std::optional<GraphicsQuery> parse(std::string_view header) noexcept {
    GraphicsQuery result;
    std::array<std::optional<std::uint32_t>, 256> values;
    while (!header.empty()) {
      const auto comma = header.find(',');
      const auto field = header.substr(0, comma);
      header = comma == std::string_view::npos ? std::string_view{} : header.substr(comma + 1);
      if (field.size() < 3 || field[1] != '=') {
        break;
      }
      auto value = field.substr(2);
      if (value.size() > 11) {
        break;
      }
      const auto key = static_cast<std::uint8_t>(field.front());
      if (value.size() == 1 && (value.front() < '0' || value.front() > '9')) {
        values[key] = static_cast<std::uint8_t>(value.front());
      } else {
        if (value.starts_with('+')) {
          value.remove_prefix(1);
        }
        if ((key == 'z' || key == 'H' || key == 'V') && value.starts_with('-')) {
          const auto number = kittyUnsigned<std::uint32_t>(value.substr(1));
          if (!number || *number > std::uint32_t{INT32_MAX} + 1) {
            return std::nullopt;
          }
          values[key] = 0u - *number;
        } else {
          const auto number = kittyUnsigned<std::uint32_t>(value);
          if (!number) {
            return std::nullopt;
          }
          values[key] = *number;
        }
      }
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
  explicit GraphicsQueries(Memory &memory)
      : allocator_(memory), decoded_(AllocatorRef<std::uint8_t, Memory>{memory}), inflated_(AllocatorRef<std::uint8_t, Memory>{memory}) {}

  void respond(std::string_view body, Reply<Memory> &reply) {
    const auto separator = body.find(';');
    const auto request = GraphicsQuery::parse(body.substr(1, separator == std::string_view::npos ? separator : separator - 1));
    if (!request || request->quiet > 1 || request->image == 0) {
      return;
    }

    const auto payload = separator == std::string_view::npos ? std::string_view{} : body.substr(separator + 1);
    if (payload.size() > maximum_encoded_bytes) {
      return;
    }
    decoded_.resize(payload.size() / 4 * 3);
    const auto decoded_size = base64::decode(payload, decoded_);
    if (!decoded_size) {
      return;
    }
    decoded_.resize(*decoded_size);

    std::string_view result;
    try {
      result = request->number != 0 ? "EINVAL: image ID and number are mutually exclusive" : validate(*request, payload);
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
  std::string_view validate(const GraphicsQuery &request, std::string_view payload) {
    if (request.format != 24 && request.format != 32 && request.format != 100) {
      return "EINVAL: unsupported format";
    }
    if (request.format != 100 && (request.width > maximum_dimension || request.height > maximum_dimension)) {
      return "EINVAL: dimensions too large";
    }
    if (request.medium == 't') {
      return "EINVAL: unsupported medium";
    }
    if (request.medium != 'd') {
      std::optional<GraphicsChildFile> file;
      if (request.medium == 'f') {
        file = GraphicsChildFile::open(payload);
      } else {
        std::array<std::uint8_t, PATH_MAX + 1> name;
        auto descriptor = GraphicsChildSharedMemory::open(payload, name);
        struct stat metadata{};
        if (descriptor && ::fstat(descriptor.get(), &metadata) == 0 && metadata.st_uid == ::getuid() && metadata.st_size > 0) {
          file = GraphicsChildFile{std::move(descriptor), static_cast<std::uint64_t>(metadata.st_size)};
        }
      }
      if (!file || request.offset > file->size) {
        return "EINVAL: invalid data";
      }
      auto count = request.length != 0 ? request.length : file->size - request.offset;
      if (request.medium == 's' && request.length == 0 && !request.compressed && request.format != 100) {
        count = static_cast<std::uint64_t>(request.width) * request.height * (request.format == 24 ? 3 : 4);
      }
      if (count > maximum_image_bytes || count > file->size - request.offset) {
        return "EINVAL: invalid data";
      }
      decoded_.resize(static_cast<std::size_t>(count));
      if (!file->read(decoded_, request.offset)) {
        return "EINVAL: invalid data";
      }
    }

    std::span<const std::uint8_t> data = decoded_;
    if (request.compressed) {
      z_stream stream{};
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
        if (inflated_.size() == maximum_image_bytes) {
          return "EINVAL: dimensions too large";
        }
        const auto start = inflated_.size();
        inflated_.resize(std::min(maximum_image_bytes, start + inflate_chunk_bytes));
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
      if (!decodePngImage(allocator_.get(), data, image)) {
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
    if (bytes > maximum_image_bytes) {
      return "EINVAL: dimensions too large";
    }
    return data.size() != bytes ? "EINVAL: invalid data" : "OK";
  }

public:
  static constexpr std::string_view invalid_encoding = "invalid-base64";

private:
  static constexpr std::size_t maximum_image_bytes = 128 * 1024 * 1024;
  static constexpr std::size_t maximum_encoded_bytes = 65 * 1024 * 1024;
  static constexpr std::size_t inflate_chunk_bytes = 64 * 1024;
  static constexpr unsigned maximum_dimension = 10000;
  GhosttyAllocatorBridge<Memory> allocator_;
  Vector<std::uint8_t, Memory> decoded_;
  Vector<std::uint8_t, Memory> inflated_;
};

}
