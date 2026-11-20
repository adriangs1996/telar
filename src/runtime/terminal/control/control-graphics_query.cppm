module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.terminal.control:graphics_query;

import std;
import telar.ghostty.vt;
import telar.native.zlib;
import telar.sys.posix;
import telar.base.memory.allocators;
import telar.platform.primitives;
import telar.runtime.terminal.ghostty;
import telar.runtime.terminal.kitty;
import :graphics_payload;
import :reply;
import telar.base.ds;

export namespace telar::runtime::control {

  struct GraphicsQuery {
    // Kitty's pixel formats: 24-bit RGB, 32-bit RGBA and PNG.
    static constexpr std::uint32_t rgb_format = 24;
    static constexpr std::uint32_t rgba_format = 32;
    static constexpr std::uint32_t png_format = 100;

    std::uint32_t image = 0;
    std::uint32_t number = 0;
    std::uint32_t placement = 0;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t format = rgba_format;
    std::uint32_t quiet = 0;
    std::uint32_t offset = 0;
    std::uint32_t length = 0;
    char medium = 'd';
    bool compressed = false;

    static ds::Option<GraphicsQuery> parse(std::string_view header, bool has_payload) noexcept;

    // Recognition survives invalid non-action fields, so malformed native
    // queries remain intercepted without a second scan or foreign response.
    static ds::Option<GraphicsQuery> parse(std::string_view header, bool has_payload, bool& query) noexcept;

    // The bytes of the raw pixels its dimensions and format describe.
    [[nodiscard]] constexpr std::uint64_t pixelBytes() const noexcept {
      return static_cast<std::uint64_t>(width) * height * (format == rgb_format ? 3 : 4);
    }

  private:
    enum class Field : std::uint8_t {
      action,
      image,
      number,
      placement,
      width,
      height,
      format,
      quiet,
      offset,
      length,
      medium,
      compression,
      ignored,
    };

    static constexpr Field parameterField(std::uint8_t key) noexcept {
      switch (key) {
      case 'a':
        return Field::action;
      case 'i':
        return Field::image;
      case 'I':
        return Field::number;
      case 'p':
        return Field::placement;
      case 's':
        return Field::width;
      case 'v':
        return Field::height;
      case 'f':
        return Field::format;
      case 'q':
        return Field::quiet;
      case 'O':
        return Field::offset;
      case 'S':
        return Field::length;
      case 't':
        return Field::medium;
      case 'o':
        return Field::compression;
      default:
        return Field::ignored;
      }
    }
  };

  // Generic over the caller's allocator, so it stays here.
  template <Allocator Memory>
  class TBC_GENERIC GraphicsQueries {
  public:
    explicit GraphicsQueries(Memory& memory, GraphicsQueryResources resources = {})
        : local_budget_(resources.limits.global_bytes),
          memory_(memory, resources.budget != nullptr ? *resources.budget : local_budget_, resources.limits.pane_bytes, resources.budget != nullptr ? resources.usage : nullptr),
          allocator_(memory_),
          decoded_(memory_),
          inflated_(memory_),
          image_limit_(std::min(resources.limits.screenBytes(), resources.limits.global_bytes)) {}

    void discard() noexcept {
      decoded_ = ds::Vec<std::uint8_t, QueryMemory>{decoded_.memory()};
      inflated_ = ds::Vec<std::uint8_t, QueryMemory>{inflated_.memory()};
    }

    bool handle(std::string_view body, Reply<Memory>& reply, bool enabled) {
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
        decoded_.resize((payload.size() / 4 * 3) + (payload.size() % 4 == 0 ? 0 : 3));
        const auto decoded_size = decodeGraphicsPayload(payload, decoded_.viewMut());
        if (!decoded_size) {
          return true;
        }

        decoded_.resize(*decoded_size);
        result = request->number != 0 ? "EINVAL: image ID and number are mutually exclusive" : validate(*request);
      } catch (const std::bad_alloc&) {
        result = "ENOMEM: out of memory";
      } catch (const std::length_error&) {
        result = "ENOMEM: out of memory";
      }

      if (result == invalid_encoding || request->quiet > 1 || (request->quiet == 1 && result == "OK")) {
        return true;
      }

      encodeReply(*request, result, reply);
      return true;
    }

  private:
    using QueryMemory = MediaAllocator<Memory>;

    static void encodeReply(const GraphicsQuery& request, std::string_view result, Reply<Memory>& reply) {
      constexpr std::size_t maximum_reply_bytes = 128;
      constexpr std::size_t identifier_digits = std::numeric_limits<std::uint32_t>::digits10 + 1;
      constexpr std::string_view image_prefix = "\x1b_Gi=";
      constexpr std::string_view number_prefix = ",I=";
      constexpr std::string_view placement_prefix = ",p=";
      constexpr std::size_t maximum_prefix_bytes = image_prefix.size() + number_prefix.size() + placement_prefix.size() + (3 * identifier_digits) + 1;
      constexpr std::string_view terminator = "\x1b\\";
      static_assert(maximum_reply_bytes > maximum_prefix_bytes + terminator.size());
      ds::Array<char, maximum_reply_bytes> encoded{};
      // One mutable borrow of the buffer, which `next` walks.
      const std::span<char> output{encoded.dataMut(), encoded.size()};
      auto* next = std::ranges::copy(image_prefix, output.data()).out;
      const auto identifier = [&](std::uint32_t value) {
        const auto formatted = std::to_chars(next, output.data() + maximum_prefix_bytes, value);

        // to_chars reports success as the errc of value 0, which names no error.
        TELAR_ASSERT(std::to_underlying(formatted.ec) == 0);
        next = formatted.ptr;
      };

      identifier(request.image);
      if (request.number != 0) {
        next = std::ranges::copy(number_prefix, next).out;
        identifier(request.number);
      }

      if (request.placement != 0) {
        next = std::ranges::copy(placement_prefix, next).out;
        identifier(request.placement);
      }

      *next++ = ';';

      // Result strings are internal diagnostics. Keep the bound explicit if a
      // future validator adds a longer message; only initialized bytes escape.
      if (result.size() > static_cast<std::size_t>(output.data() + output.size() - next) - terminator.size()) {
        throw std::length_error{"Graphics query reply exceeds its configured limit"};
      }

      next = std::ranges::copy(result, next).out;
      next = std::ranges::copy(terminator, next).out;
      reply.append({output.data(), static_cast<std::size_t>(next - output.data())});
    }

    std::string_view validate(const GraphicsQuery& request) {
      if (request.format != GraphicsQuery::rgb_format && request.format != GraphicsQuery::rgba_format && request.format != GraphicsQuery::png_format) {
        return "EINVAL: unsupported format";
      }

      if (request.format != GraphicsQuery::png_format && (request.width > maximum_dimension || request.height > maximum_dimension)) {
        return "EINVAL: dimensions too large";
      }

      if (request.medium != 'd') {
        if (const auto error = readMedium(request); !error.empty()) {
          return error;
        }
      }

      std::span<const std::uint8_t> data = decoded_;

      if (request.compressed) {
        if (const auto error = inflate(data, {.memory = memory_, .output = inflated_, .limit = image_limit_}); !error.empty()) {
          return error;
        }

        data = inflated_;
      }

      if (request.format == GraphicsQuery::png_format) {
        return validatePng(data, allocator_, image_limit_);
      }

      return validatePixels(request, data);
    }

    // Reads the image a file or shared memory object holds into decoded_, whose bytes name it; an
    // error, or nothing once read.
    std::string_view readMedium(const GraphicsQuery& request) {
      ds::Option<GraphicsChildFile> file;
      ds::Array<std::uint8_t, PATH_MAX + 1> name{};

      if (request.medium == 'f' || request.medium == 't') {
        file = GraphicsChildFile::openDecoded(decoded_);
      } else {
        auto descriptor = GraphicsChildSharedMemory::openDecoded(decoded_, name.viewMut());
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
        const char* name;

        explicit SharedCleanup(const char* shared_name) noexcept
            : name(shared_name) {}

        SharedCleanup(const SharedCleanup&) = delete;
        SharedCleanup& operator=(const SharedCleanup&) = delete;
        SharedCleanup(SharedCleanup&&) = delete;
        SharedCleanup& operator=(SharedCleanup&&) = delete;

        ~SharedCleanup() {
          if (name != nullptr) {
            ::shm_unlink(name);
          }
        }
      } shared{request.medium == 's' ? reinterpret_cast<const char*>(name.data()) : nullptr}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): shm_unlink takes the name openDecoded wrote as bytes, and char may alias them

      auto count = request.length != 0 ? request.length : file->size - request.offset;

      if (request.medium == 's' && request.length == 0 && !request.compressed && request.format != GraphicsQuery::png_format) {
        count = request.pixelBytes();
      }

      if (count > image_limit_ || count > file->size - request.offset) {
        return "EINVAL: invalid data";
      }

      decoded_.resize(static_cast<std::size_t>(count));
      const bool read = request.medium == 's' ? GraphicsChildSharedMemory::read(file->descriptor.get(), decoded_.viewMut(), request.offset) : file->read(decoded_.viewMut(), request.offset);
      if (!read) {
        return "EINVAL: invalid data";
      }

      return {};
    }

    // Where inflate() writes, from what memory, and how much at most.
    struct InflateTarget {
      QueryMemory& memory;
      ds::Vec<std::uint8_t, QueryMemory>& output;
      std::size_t limit;
    };

    // Inflates data into the target's output; an error, or nothing once inflated.
    static tbc::val_static<std::string_view> inflate(std::span<const std::uint8_t> data, InflateTarget target) {
      z_stream stream{};
      auto& inflated = target.output;

      stream.opaque = &target.memory;
      stream.zalloc = &allocateInflate;
      stream.zfree = &freeInflate;
      if (::inflateInit(&stream) != Z_OK) {
        return "EINVAL: decompression failed";
      }

      struct Inflater {
        z_stream& stream;

        explicit Inflater(z_stream& owned) noexcept
            : stream(owned) {}

        Inflater(const Inflater&) = delete;
        Inflater& operator=(const Inflater&) = delete;
        Inflater(Inflater&&) = delete;
        Inflater& operator=(Inflater&&) = delete;

        ~Inflater() {
          ::inflateEnd(&stream);
        }
      } owner{stream};

      stream.next_in = const_cast<Bytef*>(data.data()); // NOLINT(cppcoreguidelines-pro-type-const-cast): zlib declares next_in mutable without ZLIB_CONST, and inflate only reads it
      stream.avail_in = static_cast<uInt>(data.size());
      inflated.clear();
      int status = Z_OK;

      while (status == Z_OK) {
        if (inflated.size() == target.limit) {
          return "EINVAL: dimensions too large";
        }

        const auto start = inflated.size();

        inflated.resize(std::min(target.limit, start + inflate_chunk_bytes));
        stream.next_out = inflated.dataMut() + start;
        stream.avail_out = static_cast<uInt>(inflated.size() - start);
        status = ::inflate(&stream, Z_NO_FLUSH);
        inflated.resize(inflated.size() - stream.avail_out);
      }

      if (status != Z_STREAM_END) {
        return "EINVAL: decompression failed";
      }

      return {};
    }

    static tbc::val_static<std::string_view> validatePng(std::span<const std::uint8_t> data, GhosttyAllocatorBridge<QueryMemory>& allocator, std::size_t limit) {
      GhosttySysImage image{};
      if (!decodePngImage(allocator.get(), data, image, limit)) {
        return "EINVAL: invalid data";
      }

      // ghostty's allocator, which C reaches by address, frees the image it decoded.
      ghostty_free(tbc::raw(allocator.get()), image.data, image.data_len);
      return image.width > maximum_dimension || image.height > maximum_dimension ? "EINVAL: dimensions too large" : "OK";
    }

    std::string_view validatePixels(const GraphicsQuery& request, std::span<const std::uint8_t> data) const {
      if (request.width == 0 || request.height == 0) {
        return "EINVAL: dimensions required";
      }

      if (request.width > maximum_dimension || request.height > maximum_dimension) {
        return "EINVAL: dimensions too large";
      }

      const auto bytes = request.pixelBytes();
      if (bytes > image_limit_) {
        return "EINVAL: dimensions too large";
      }

      return data.size() != bytes ? "EINVAL: invalid data" : "OK";
    }

  public:
    static constexpr std::string_view invalid_encoding = "invalid-base64";

  private:
    struct alignas(std::max_align_t) InflateAllocation {
      std::size_t bytes;
    };

    static void* allocateInflate(void* context, unsigned count, unsigned size) noexcept {
      if (size != 0 && count > (std::numeric_limits<std::size_t>::max() - sizeof(InflateAllocation)) / size) {
        return nullptr;
      }

      const auto bytes = (static_cast<std::size_t>(count) * size) + sizeof(InflateAllocation);
      auto* allocation = static_cast<InflateAllocation*>(static_cast<QueryMemory*>(context)->allocate(bytes, alignof(InflateAllocation)));
      if (allocation == nullptr) {
        return nullptr;
      }

      allocation->bytes = bytes;
      return allocation + 1;
    }

    static void freeInflate(void* context, void* pointer) noexcept { // NOLINT(bugprone-easily-swappable-parameters): zlib's free_func signature
      if (pointer != nullptr) {
        auto* allocation = static_cast<InflateAllocation*>(pointer) - 1;

        static_cast<QueryMemory*>(context)->deallocate(allocation, allocation->bytes, alignof(InflateAllocation));
      }
    }

    static constexpr std::size_t maximum_encoded_bytes = std::size_t{65} * 1024 * 1024;
    static constexpr std::size_t inflate_chunk_bytes = std::size_t{64} * 1024;
    static constexpr unsigned maximum_dimension = 10000;
    MediaBudget local_budget_;
    QueryMemory memory_;
    GhosttyAllocatorBridge<QueryMemory> allocator_;
    ds::Vec<std::uint8_t, QueryMemory> decoded_;
    ds::Vec<std::uint8_t, QueryMemory> inflated_;
    std::size_t image_limit_;
  };

}
