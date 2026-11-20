module telar.git;

import std;
import telar.native.zlib;
import telar.sys.posix;
import telar.base.text;
import telar.platform.fs;
import telar.base.ds;

namespace telar::git {

  using telar::runtime::substring;

  namespace {

    constexpr unsigned byte_bits = 8;
    constexpr unsigned word_bits = 32;

    // A pack entry's header byte: the type above four bits of the size.
    constexpr unsigned pack_type_shift = 4;
    constexpr std::uint8_t pack_type_mask = 7;
    constexpr std::uint8_t pack_size_mask = 0xf;

    // A size shift past which another seven bits overflow 64.
    constexpr unsigned maximum_size_shift = 57;

    // The pack entry types besides the four object types.
    constexpr std::uint8_t pack_reserved = 5;
    constexpr std::uint8_t pack_offset_delta = 6;
    constexpr std::uint8_t pack_reference_delta = 7;

    // A packfile starts with "PACK", its version and its object count.
    constexpr std::size_t pack_header_bytes = 12;
    constexpr std::string_view pack_signature = "PACK";

    // A v2 pack index: its signature, then after the ids a CRC and an offset per object, then the
    // offsets past 2 GiB.
    constexpr ds::Array<std::uint8_t, 4> pack_index_signature{0xff, 't', 'O', 'c'};
    constexpr std::size_t pack_crc_bytes = 4;
    constexpr std::size_t pack_offset_bytes = 4;
    constexpr std::size_t pack_large_offset_bytes = 8;
    constexpr std::uint32_t pack_large_offset = 0x80000000U;
    constexpr std::uint32_t pack_offset_mask = 0x7fffffffU;

    constexpr std::string_view pack_index_suffix = ".idx";
    constexpr std::size_t maximum_pack_name = 128;

    // A delta's copy operation: the flag, then flags for the four offset and three size bytes that
    // follow it.
    constexpr std::uint8_t delta_copy = 0x80;
    constexpr unsigned delta_copy_arguments = 7;
    constexpr unsigned delta_copy_offset_bytes = 4;
    constexpr std::uint64_t delta_copy_default_size = 0x10000;

    // A commit-graph: its header, a table of chunks, and per commit its id then 16 bytes of parents,
    // generation and time.
    constexpr std::string_view graph_signature = "CGPH";
    constexpr std::size_t graph_header_bytes = 8;
    constexpr std::size_t graph_version_at = 4;
    constexpr std::size_t graph_hash_version_at = 5;
    constexpr std::size_t graph_chunk_count_at = 6;
    constexpr std::size_t graph_base_count_at = 7;
    constexpr std::size_t graph_chunk_entry_bytes = 12;
    constexpr std::size_t graph_chunk_id_bytes = 4;
    constexpr std::size_t graph_commit_data_bytes = 16;
    constexpr std::uint8_t graph_sha256_version = 2;
    constexpr unsigned graph_generation_shift = 2;
    constexpr std::uint32_t graph_time_high_mask = 3;
    constexpr std::uint32_t graph_extra_edges = 0x80000000U;
    constexpr std::uint32_t graph_last_edge = 0x80000000U;
    constexpr std::uint32_t graph_edge_mask = 0x7fffffffU;
    constexpr std::size_t graph_edge_bytes = 4;
    constexpr std::size_t maximum_graph_chunks = 32;

    constexpr std::uint32_t graph_chunk_fanout = 0x4f494446;  // OIDF
    constexpr std::uint32_t graph_chunk_ids = 0x4f49444c;     // OIDL
    constexpr std::uint32_t graph_chunk_commits = 0x43444154; // CDAT
    constexpr std::uint32_t graph_chunk_edges = 0x45444745;   // EDGE

    enum class Inflated : std::uint8_t {
      full,
      ended,
      failed,
    };

    // Compressed bytes held in memory, handed to zlib once.
    struct MemorySource {
      std::span<const std::uint8_t> bytes;

      std::span<const std::uint8_t> next() noexcept {
        return std::exchange(bytes, {});
      }
    };

    // Compressed bytes read from a packfile in chunks, up to its trailer.
    struct PackSource {
      int descriptor;
      std::uint64_t offset;
      std::uint64_t end;
      std::span<std::uint8_t> buffer;

      std::span<const std::uint8_t> next() noexcept {
        if (offset >= end) {
          return {};
        }

        const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(buffer.size(), end - offset));
        if (!readAt(descriptor, buffer.first(count), offset)) {
          return {};
        }

        offset += count;
        return buffer.first(count);
      }
    };

    // Continues `stream` until `output` is full or the stream ends.
    template <typename Source>
    Inflated pump(z_stream& stream, Source& source, std::span<std::uint8_t> output) noexcept {
      if (output.size() > std::numeric_limits<unsigned>::max()) {
        return Inflated::failed;
      }

      stream.next_out = output.data();
      stream.avail_out = static_cast<uInt>(output.size());
      for (;;) {
        if (stream.avail_in == 0) {
          const auto chunk = source.next();
          if (chunk.empty()) {
            return Inflated::failed;
          }

          stream.next_in = const_cast<Bytef*>(chunk.data());
          stream.avail_in = static_cast<uInt>(chunk.size());
        }

        const auto result = ::inflate(&stream, Z_NO_FLUSH);
        if (result == Z_STREAM_END) {
          return Inflated::ended;
        }

        if (result != Z_OK && result != Z_BUF_ERROR) {
          return Inflated::failed;
        }

        if (stream.avail_out == 0) {
          return Inflated::full;
        }

        if (result == Z_BUF_ERROR && stream.avail_in != 0) {
          return Inflated::failed;
        }
      }
    }

    // After `output` filled, the stream must end without producing another byte.
    template <typename Source>
    bool endsHere(z_stream& stream, Source& source) noexcept {
      ds::Array<std::uint8_t, 1> sink{};

      return pump(stream, source, sink.viewMut()) == Inflated::ended && stream.avail_out == sink.size();
    }

    // Inflates the first output.size() bytes of a stream at least that long.
    template <typename Source>
    bool inflatePrefix(z_stream& stream, Source& source, std::span<std::uint8_t> output) noexcept {
      if (output.empty()) {
        return true;
      }

      const auto result = pump(stream, source, output);

      return result == Inflated::full || (result == Inflated::ended && stream.avail_out == 0);
    }

    // Inflates the whole stream, which must hold exactly output.size() bytes.
    template <typename Source>
    bool inflateExactly(z_stream& stream, Source& source, std::span<std::uint8_t> output) noexcept {
      if (output.empty()) {
        return endsHere(stream, source);
      }

      switch (pump(stream, source, output)) {
      case Inflated::ended:
        return stream.avail_out == 0;
      case Inflated::full:
        return endsHere(stream, source);
      case Inflated::failed:
        return false;
      }

      return false;
    }

    std::span<std::uint8_t> writable(auto& string) noexcept {
#pragma clang unsafe_buffer_usage begin
      return {reinterpret_cast<std::uint8_t*>(string.dataMut()), string.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): bytes may alias text, and no cast-free view writes text as bytes
#pragma clang unsafe_buffer_usage end
    }

    // Little-endian base-128 size of a delta header; none when it runs past the delta or 64 bits.
    ds::Option<std::uint64_t> deltaSize(std::span<const std::uint8_t> delta, std::size_t& position) noexcept {
      std::uint64_t value = 0;

      for (unsigned shift = 0; shift < std::numeric_limits<std::uint64_t>::digits; shift += varint_payload_bits) {
        if (position >= delta.size()) {
          return ds::none;
        }

        const auto byte = delta[position++];

        value |= (std::uint64_t{byte} & varint_payload) << shift;
        if ((byte & varint_continues) == 0) {
          return value;
        }
      }

      return ds::none;
    }

    // The source range a delta's copy operation names.
    struct DeltaCopy {
      std::uint64_t offset = 0;
      std::uint64_t size = 0;
    };

    // The offset and size bytes `operation` flags, read from `delta` at `position`; none when the
    // delta ends first.
    ds::Option<DeltaCopy> deltaCopy(std::span<const std::uint8_t> delta, std::size_t& position, std::uint8_t operation) noexcept {
      DeltaCopy copy;

      for (unsigned bit = 0; bit < delta_copy_arguments; ++bit) {
        if ((operation & (1U << bit)) == 0) {
          continue;
        }

        if (position >= delta.size()) {
          return ds::none;
        }

        const auto byte = std::uint64_t{delta[position++]};

        if (bit < delta_copy_offset_bytes) {
          copy.offset |= byte << (byte_bits * bit);
        } else {
          copy.size |= byte << (byte_bits * (bit - delta_copy_offset_bytes));
        }
      }

      if (copy.size == 0) {
        copy.size = delta_copy_default_size;
      }

      return copy;
    }

    // Applies a git delta to `base`. Every copy is checked against both buffers.
    template <Allocator Memory>
    bool applyDelta(std::span<const std::uint8_t> base, std::span<const std::uint8_t> delta, ds::String<Memory>& output, std::size_t limit) {
      std::size_t position = 0;
      const auto source_size = deltaSize(delta, position);
      const auto target_size = source_size ? deltaSize(delta, position) : ds::none;
      if (!target_size || *source_size != base.size() || *target_size > limit) {
        return false;
      }

      resizeForOverwrite(output, static_cast<std::size_t>(*target_size));
      const auto target = writable(output);
      std::size_t written = 0;

      while (position < delta.size()) {
        const auto operation = delta[position++];
        if ((operation & delta_copy) != 0) {
          const auto copy = deltaCopy(delta, position, operation);
          if (!copy || !fits(base.size(), copy->offset, copy->size) || !fits(*target_size, written, copy->size)) {
            return false;
          }

          std::ranges::copy(base.subspan(static_cast<std::size_t>(copy->offset), static_cast<std::size_t>(copy->size)), target.subspan(written).begin());
          written += static_cast<std::size_t>(copy->size);
        } else if (operation != 0) {
          if (!fits(delta.size(), position, operation) || !fits(*target_size, written, operation)) {
            return false;
          }

          std::ranges::copy(delta.subspan(position, operation), target.subspan(written).begin());
          position += operation;
          written += operation;
        } else {
          return false;
        }
      }

      return written == *target_size;
    }

    ds::Option<ObjectId> headerId(std::string_view& content, std::string_view label, ObjectFormat format) noexcept {
      const auto digits = 2 * hashSize(format);
      if (!content.starts_with(label) || content.size() < label.size() + digits + 1 || content[label.size() + digits] != '\n') {
        return ds::none;
      }

      const auto id = ObjectId::fromHex(substring(content, label.size(), digits), format);
      if (id) {
        content.remove_prefix(label.size() + digits + 1);
      }

      return id;
    }

    // The byte of a tree entry's name that git's tree order compares after their common prefix: a
    // directory's name ends with '/'.
    unsigned char treeNameByte(std::string_view name, std::size_t position, bool directory) noexcept {
      if (name.size() > position) {
        return static_cast<unsigned char>(name[position]);
      }

      return directory ? '/' : 0;
    }

    // The type a loose object's header names; none for any other.
    ds::Option<ObjectType> looseType(std::string_view kind) noexcept {
      if (kind == "commit") {
        return ObjectType::commit;
      }

      if (kind == "tree") {
        return ObjectType::tree;
      }

      if (kind == "blob") {
        return ObjectType::blob;
      }

      if (kind == "tag") {
        return ObjectType::tag;
      }

      return ds::none;
    }

    // A loose object's header, "<type> <size>\0": the type, the size, and the header's length.
    struct LooseHeader {
      ObjectType type = ObjectType::none;
      std::uint64_t size = 0;
      std::size_t length = 0;
    };

    // The header at the front of `text`; none when it is malformed.
    ds::Option<LooseHeader> looseHeader(std::string_view text) noexcept {
      const auto space = text.find(' ');
      const auto terminator = text.find('\0');
      if (space == std::string_view::npos || terminator == std::string_view::npos || space > terminator) {
        return ds::none;
      }

      const auto type = looseType(substring(text, 0, space));
      const auto size = telar::runtime::parseExact<std::uint64_t>(substring(text, space + 1, terminator - space - 1));
      if (!type || !size) {
        return ds::none;
      }

      return LooseHeader{.type = *type, .size = *size, .length = terminator + 1};
    }

  }

  Inflater::Inflater(Memory& memory) noexcept
      : blocks_(memory) {}

  Inflater::~Inflater() {
    if (ready_) {
      ::inflateEnd(&stream_);
    }
  }

  bool Inflater::start() noexcept {
    if (!ready_) {
      stream_ = {};
      stream_.zalloc = &allocate;
      stream_.zfree = &release;
      stream_.opaque = &blocks_;
      ready_ = ::inflateInit(&stream_) == Z_OK;
      return ready_;
    }

    stream_.next_in = nullptr;
    stream_.avail_in = 0;
    return ::inflateReset(&stream_) == Z_OK;
  }

  z_stream& Inflater::stream() noexcept {
    return stream_;
  }

  voidpf Inflater::allocate(voidpf opaque, uInt items, uInt size) noexcept {
    return static_cast<CAllocationBlocks<Memory>*>(opaque)->allocateZeroed(items, size);
  }

  void Inflater::release(voidpf opaque, voidpf address) noexcept {
    static_cast<CAllocationBlocks<Memory>*>(opaque)->release(address);
  }

  void resizeForOverwrite(ds::String<Memory>& string, std::size_t size) {
    string.resizeForOverwrite(size);
  }

  bool parseCommit(std::string_view content, ObjectFormat format, std::size_t maximum_parents, CommitHeader& header, ds::Vec<ObjectId, Memory>& parents) {
    const auto tree = headerId(content, "tree ", format);
    if (!tree) {
      return false;
    }

    header.tree = *tree;
    const auto first = parents.size();

    while (content.starts_with("parent ")) {
      const auto parent = headerId(content, "parent ", format);
      if (!parent || parents.size() - first >= maximum_parents) {
        return false;
      }

      parents.push(*parent);
    }

    while (!content.empty() && content.front() != '\n') {
      const auto end = content.find('\n');
      if (end == std::string_view::npos) {
        return false;
      }

      const auto line = substring(content, 0, end);

      content.remove_prefix(end + 1);
      if (!line.starts_with("committer ")) {
        continue;
      }

      const auto email_end = line.rfind('>');
      if (email_end == std::string_view::npos) {
        return false;
      }

      auto rest = substring(line, email_end + 1);

      while (rest.starts_with(' ')) {
        rest.remove_prefix(1);
      }

      const auto seconds = telar::runtime::parseExact<std::uint64_t>(substring(rest, 0, rest.find_first_not_of("0123456789")));
      if (!seconds) {
        return false;
      }

      header.time = static_cast<std::int64_t>(std::min<std::uint64_t>(*seconds, std::numeric_limits<std::int64_t>::max()));
      return true;
    }

    return false;
  }

  bool TreeEntry::directory() const noexcept {
    return (mode & mode_type_mask) == mode_directory;
  }

  int compareTreeNames(std::string_view left, bool left_directory, std::string_view right, bool right_directory) noexcept {
    const auto common = std::min(left.size(), right.size());
    if (const auto order = substring(left, 0, common).compare(substring(right, 0, common)); order != 0) {
      return order;
    }

    const auto left_next = treeNameByte(left, common, left_directory);
    const auto right_next = treeNameByte(right, common, right_directory);
    if (left_next == right_next) {
      return 0;
    }

    return left_next < right_next ? -1 : 1;
  }

  TreeReader::TreeReader(tbc::val_a<std::string_view> content, ObjectFormat format) noexcept
      : rest_(content),
        hash_size_(hashSize(format)) {}

  bool TreeReader::next(tbc::mut_a<TreeEntry> entry) noexcept {
    if (rest_.empty() || failed_) {
      return false;
    }

    constexpr std::size_t maximum_mode_digits = 7;
    constexpr unsigned octal_digit_bits = 3;

    std::uint32_t mode = 0;
    std::size_t index = 0;

    while (index < rest_.size() && index < maximum_mode_digits && rest_[index] >= '0' && rest_[index] <= '7') {
      mode = mode << octal_digit_bits | static_cast<std::uint32_t>(rest_[index] - '0');
      ++index;
    }

    if (index == 0 || index >= rest_.size() || rest_[index] != ' ') {
      return fail();
    }

    const auto name_start = index + 1;
    const auto name_end = rest_.find('\0', name_start);
    if (name_end == std::string_view::npos || name_end == name_start || !fits(rest_.size(), name_end + 1, hash_size_)) {
      return fail();
    }

    const auto name = substring(rest_, name_start, name_end - name_start);
    if (name == "." || name == ".." || name.contains('/')) {
      return fail();
    }

    switch (mode) {
    case mode_directory:
    case mode_file:
    case mode_executable:
    case mode_group_writable:
    case mode_symlink:
    case mode_gitlink:
      break;
    default:
      return fail();
    }

    entry.mode = mode == mode_group_writable ? mode_file : mode;
    entry.name = name;
    entry.id = ObjectId::fromBytes(asBytes(substring(rest_, name_end + 1, hash_size_)));
    if (have_previous_ && compareTreeNames(previous_, previous_directory_, name, entry.directory()) >= 0) {
      return fail();
    }

    previous_ = name;
    previous_directory_ = entry.directory();
    have_previous_ = true;
    rest_.remove_prefix(name_end + 1 + hash_size_);
    return true;
  }

  bool TreeReader::failed() const noexcept {
    return failed_;
  }

  bool TreeReader::fail() noexcept {
    failed_ = true;
    return false;
  }

  ObjectDatabase::ObjectDatabase(Memory& memory) noexcept
      : inflater_(memory),
        packs_(memory),
        chain_(memory),
        compressed_(memory),
        base_(memory),
        target_(memory),
        delta_(memory) {}

  bool ObjectDatabase::open(int common, ObjectFormat format, const Limits& limits) {
    limits_ = limits;
    inflated_ = 0;
    if (format != format_ || !objects_) {
      packs_.clear();
      packs_identity_ = {};
    }

    format_ = format;
    objects_ = openDirectory(common, "objects");
    if (!objects_) {
      packs_.clear();
      return false;
    }

    refreshPacks();
    return true;
  }

  void ObjectDatabase::close() noexcept {
    objects_.reset();
    packs_.clear();
    packs_identity_ = {};
  }

  int ObjectDatabase::objects() const noexcept {
    return objects_.get();
  }

  ObjectFormat ObjectDatabase::format() const noexcept {
    return format_;
  }

  Lookup ObjectDatabase::read(const ObjectId& id, ObjectType& type, ds::String<Memory>& output, std::size_t prefix) {
    Location location;
    const auto located = locate(id, location);
    if (located != Lookup::found) {
      return located;
    }

    ++objects_read_;
    if (location.pack == loose) {
      return readLoose(id, type, output, prefix);
    }

    return readPacked(location, type, output, prefix);
  }

  std::uint64_t ObjectDatabase::objectsRead() const noexcept {
    return objects_read_;
  }

  void ObjectDatabase::resetObjectsRead() noexcept {
    objects_read_ = 0;
  }

  void ObjectDatabase::trim() {
    constexpr std::size_t retained = std::size_t{1} << 20U;

    for (auto* buffer : {&compressed_, &base_, &target_, &delta_}) {
      if (buffer->capacity() > retained) {
        buffer->clear();
        buffer->shrinkToFit();
      }
    }
  }

  void ObjectDatabase::refreshPacks() {
    auto directory = openDirectory(objects_.get(), "pack");
    if (!directory) {
      packs_.clear();
      packs_identity_ = {};
      return;
    }

    struct stat status{};
    if (::fstat(directory.get(), &status) != 0) {
      packs_.clear();
      return;
    }

    const auto identity = fingerprintOf(status);
    if (identity == packs_identity_) {
      return;
    }

    packs_.clear();
    packs_identity_ = {};
    telar::runtime::DirectoryStream stream{directory.get()};

    while (const auto* entry = stream.next()) {
      const std::string_view name{std::data(entry->d_name)};
      if (!name.starts_with("pack-") || !name.ends_with(pack_index_suffix) || name.size() > maximum_pack_name) {
        continue;
      }

      if (packs_.size() >= limits_.packs) {
        break;
      }

      Pack pack;
      if (openPack(directory.get(), name, pack)) {
        packs_.push(std::move(pack));
      }
    }

    packs_identity_ = identity;
  }

  bool ObjectDatabase::openPack(int directory, std::string_view index_name, Pack& pack) noexcept {
    const auto hash_size = hashSize(format_);
    PathName name;
    struct stat status{};
    if (!name.assign({index_name}) || openRegular(directory, name.cString(), pack.index, status) != ReadStatus::ok) {
      return false;
    }

    pack.index_size = static_cast<std::uint64_t>(status.st_size);
    ds::Array<std::uint8_t, pack_index_header> header{};
    if (pack.index_size < pack_index_header + (2 * hash_size) || !readAt(pack.index.get(), header.viewMut(), 0)) {
      return false;
    }

    if (!std::ranges::equal(header.view().first(pack_index_signature.size()), pack_index_signature.view()) || loadBig32(header.view(), pack_index_signature.size()) != 2) {
      return false;
    }

    std::uint32_t previous = 0;

    for (std::size_t index = 0; index < pack.fanout.size(); ++index) {
      pack.fanout.atMut(index) = loadBig32(header.view(), pack_index_fanout + (sizeof(std::uint32_t) * index));
      if (pack.fanout[index] < previous) {
        return false;
      }

      previous = pack.fanout[index];
    }

    pack.count = pack.fanout.back();
    const auto fixed = pack_index_header + (std::uint64_t{pack.count} * (hash_size + pack_crc_bytes + pack_offset_bytes)) + (2 * hash_size);
    if (pack.index_size < fixed || (pack.index_size - fixed) % pack_large_offset_bytes != 0 || (pack.index_size - fixed) / pack_large_offset_bytes > pack.count) {
      return false;
    }

    pack.large_offsets = (pack.index_size - fixed) / pack_large_offset_bytes;

    const auto stem = substring(index_name, 0, index_name.size() - pack_index_suffix.size());
    if (!name.assign({stem, ".pack"}) || openRegular(directory, name.cString(), pack.data, status) != ReadStatus::ok) {
      return false;
    }

    pack.data_size = static_cast<std::uint64_t>(status.st_size);
    ds::Array<std::uint8_t, pack_header_bytes> pack_header{};
    if (pack.data_size < pack_header.size() + hash_size || !readAt(pack.data.get(), pack_header.viewMut(), 0)) {
      return false;
    }

    const auto version = loadBig32(pack_header.view(), pack_signature.size());

    return asText(pack_header.view().first(pack_signature.size())) == pack_signature && (version == 2 || version == 3) && loadBig32(pack_header.view(), pack_signature.size() + sizeof(version)) == pack.count;
  }

  ds::Option<std::uint32_t> ObjectDatabase::findInPack(std::span<std::uint8_t> block, const Pack& pack, const ObjectId& id) noexcept {
    const auto hash_size = std::size_t{id.size};
    const auto first = id.bytes[0];
    std::uint32_t low = first == 0 ? 0 : pack.fanout[first - 1];
    std::uint32_t high = pack.fanout[first];
    const auto key = id.view();

    while (high > low && std::size_t{high - low} * hash_size > block.size()) {
      const auto middle = low + ((high - low) / 2);
      ds::Array<std::uint8_t, maximum_hash_size> name{};
      if (!readAt(pack.index.get(), name.viewMut().first(hash_size), pack_index_header + (std::uint64_t{middle} * hash_size))) {
        return ds::none;
      }

      const auto order = compareBytes(key, name.view().first(hash_size));
      if (order == 0) {
        return middle;
      }

      if (order < 0) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }

    if (high <= low) {
      return ds::none;
    }

    const auto count = std::size_t{high - low};
    if (!readAt(pack.index.get(), block.first(count * hash_size), pack_index_header + (std::uint64_t{low} * hash_size))) {
      return ds::none;
    }

    std::size_t begin = 0;
    std::size_t end = count;

    while (begin < end) {
      const auto middle = begin + ((end - begin) / 2);
      const auto order = compareBytes(key, block.subspan(middle * hash_size, hash_size));
      if (order == 0) {
        return low + static_cast<std::uint32_t>(middle);
      }

      if (order < 0) {
        end = middle;
      } else {
        begin = middle + 1;
      }
    }

    return ds::none;
  }

  ds::Option<std::uint64_t> ObjectDatabase::packOffset(ObjectFormat format, const Pack& pack, std::uint32_t position) noexcept {
    const auto hash_size = hashSize(format);
    const auto offsets = pack_index_header + (std::uint64_t{pack.count} * (hash_size + pack_crc_bytes));
    ds::Array<std::uint8_t, pack_large_offset_bytes> bytes{};
    if (!readAt(pack.index.get(), bytes.viewMut().first(pack_offset_bytes), offsets + (pack_offset_bytes * std::uint64_t{position}))) {
      return ds::none;
    }

    std::uint64_t offset = loadBig32(bytes.view());
    if ((offset & pack_large_offset) != 0) {
      const auto large = offset & pack_offset_mask;
      if (large >= pack.large_offsets || !readAt(pack.index.get(), bytes.viewMut(), offsets + (pack_offset_bytes * std::uint64_t{pack.count}) + (pack_large_offset_bytes * large))) {
        return ds::none;
      }

      offset = loadBig64(bytes.view());
    }

    if (offset < pack_header_bytes || offset >= pack.data_size - hash_size) {
      return ds::none;
    }

    return offset;
  }

  Lookup ObjectDatabase::locate(const ObjectId& id, Location& location) {
    if (id.size != hashSize(format_)) {
      return Lookup::invalid;
    }

    for (std::size_t step = 0; step < packs_.size(); ++step) {
      const auto index = (last_pack_ + step) % packs_.size();
      if (const auto position = findInPack(block_.viewMut(), packs_[index], id)) {
        const auto found = packOffset(format_, packs_[index], *position);
        if (!found) {
          return Lookup::invalid;
        }

        last_pack_ = index;
        location = {.pack = static_cast<std::uint32_t>(index), .offset = *found};
        return Lookup::found;
      }
    }

    ds::Array<char, 2 * maximum_hash_size> hex{};
    const auto digits = id.hex(hex.viewMut());
    PathName name;
    if (!name.assign({substring(digits, 0, 2), "/", substring(digits, 2)})) {
      return Lookup::invalid;
    }

    struct stat status{};
    if (::fstatat(objects_.get(), name.cString(), &status, AT_SYMLINK_NOFOLLOW) != 0) {
      return sys::lastError() == ENOENT || sys::lastError() == ENOTDIR ? Lookup::missing : Lookup::invalid;
    }

    location.pack = loose;
    return Lookup::found;
  }

  bool ObjectDatabase::entryAt(ObjectFormat format, const Pack& pack, std::uint64_t offset, Entry& entry) noexcept {
    const auto hash_size = hashSize(format);
    const auto end = pack.data_size - hash_size;
    if (offset < pack_header_bytes || offset >= end) {
      return false;
    }

    // The longest entry header: the size's bytes, then a base's id or distance.
    constexpr std::size_t entry_header_bytes = 64;

    ds::Array<std::uint8_t, entry_header_bytes> bytes{};
    const auto available = static_cast<std::size_t>(std::min<std::uint64_t>(bytes.size(), end - offset));
    if (!readAt(pack.data.get(), bytes.viewMut().first(available), offset)) {
      return false;
    }

    std::size_t index = 0;
    auto byte = bytes[index++];

    entry.kind = static_cast<std::uint8_t>((unsigned{byte} >> pack_type_shift) & pack_type_mask);
    entry.size = byte & pack_size_mask;
    unsigned shift = pack_type_shift;

    while ((byte & varint_continues) != 0) {
      if (index >= available || shift > maximum_size_shift) {
        return false;
      }

      byte = bytes[index++];
      entry.size |= (std::uint64_t{byte} & varint_payload) << shift;
      shift += varint_payload_bits;
    }

    if (entry.kind == pack_offset_delta) {
      if (index >= available) {
        return false;
      }

      byte = bytes[index++];
      std::uint64_t distance = byte & varint_payload;

      while ((byte & varint_continues) != 0) {
        if (index >= available || distance >= maximum_offset_varint) {
          return false;
        }

        byte = bytes[index++];
        distance = ((distance + 1) << varint_payload_bits) | (std::uint64_t{byte} & varint_payload);
      }

      if (distance == 0 || distance > offset - pack_header_bytes) {
        return false;
      }

      entry.base_offset = offset - distance;
    } else if (entry.kind == pack_reference_delta) {
      if (!fits(available, index, hash_size)) {
        return false;
      }

      entry.base = ObjectId::fromBytes(bytes.view().subspan(index, hash_size));
      index += hash_size;
    } else if (entry.kind == 0 || entry.kind == pack_reserved) {
      return false;
    }

    entry.data_offset = offset + index;
    return true;
  }

  bool ObjectDatabase::inflatePacked(Inflater& inflater, std::span<std::uint8_t> chunk, ObjectFormat format, Inflation inflation) {
    if (!inflater.start()) {
      return false;
    }

    PackSource source{.descriptor = inflation.pack.data.get(), .offset = inflation.data_offset, .end = inflation.pack.data_size - hashSize(format), .buffer = chunk};

    if (inflation.whole) {
      return inflateExactly(inflater.stream(), source, inflation.output);
    }

    return inflatePrefix(inflater.stream(), source, inflation.output);
  }

  Lookup ObjectDatabase::readPacked(Location location, ObjectType& type, ds::String<Memory>& output, std::size_t prefix) {
    chain_.clear();
    Entry entry;
    ds::Option<ObjectId> loose_base;
    if (!chainToBase(location, entry, loose_base)) {
      return Lookup::invalid;
    }

    if (chain_.empty()) {
      if (entry.size > limits_.object_size && prefix == 0) {
        return Lookup::invalid;
      }

      const auto size = static_cast<std::size_t>(prefix == 0 ? entry.size : std::min<std::uint64_t>(entry.size, prefix));
      if (!charge(inflated_, limits_.inflated_bytes, size)) {
        return Lookup::invalid;
      }

      resizeForOverwrite(output, size);
      if (!inflatePacked(inflater_, chunk_.viewMut(), format_, {.pack = packs_[location.pack], .data_offset = entry.data_offset, .output = writable(output), .whole = prefix == 0 || size == entry.size})) {
        return Lookup::invalid;
      }

      type = static_cast<ObjectType>(entry.kind);
      return Lookup::found;
    }

    if (loose_base) {
      // The base buffer, taken while the loose object is read into it: reading mutates the database.
      auto base = std::move(base_);
      const auto read = readLoose(*loose_base, type, base, 0);

      base_ = std::move(base);
      if (read != Lookup::found) {
        return Lookup::invalid;
      }
    } else {
      if (entry.size > limits_.object_size || !charge(inflated_, limits_.inflated_bytes, entry.size)) {
        return Lookup::invalid;
      }

      resizeForOverwrite(base_, static_cast<std::size_t>(entry.size));
      if (!inflatePacked(inflater_, chunk_.viewMut(), format_, {.pack = packs_[location.pack], .data_offset = entry.data_offset, .output = writable(base_), .whole = true})) {
        return Lookup::invalid;
      }

      type = static_cast<ObjectType>(entry.kind);
    }

    if (!applyChain()) {
      return Lookup::invalid;
    }

    std::swap(output, base_);
    if (prefix != 0 && output.size() > prefix) {
      output.resize(prefix);
    }

    return Lookup::found;
  }

  bool ObjectDatabase::chainToBase(Location& location, Entry& entry, ds::Option<ObjectId>& loose_base) {
    for (;;) {
      if (!entryAt(format_, packs_[location.pack], location.offset, entry)) {
        return false;
      }

      if (entry.kind >= 1 && entry.kind <= 4) {
        return true;
      }

      if (chain_.size() >= limits_.delta_depth || entry.size > limits_.object_size) {
        return false;
      }

      chain_.push({.pack = location.pack, .data_offset = entry.data_offset, .size = entry.size});
      if (entry.kind == pack_offset_delta) {
        location.offset = entry.base_offset;
        continue;
      }

      Location base;
      if (locate(entry.base, base) != Lookup::found) {
        return false;
      }

      if (base.pack == loose) {
        loose_base = entry.base;
        return true;
      }

      location = base;
    }
  }

  bool ObjectDatabase::applyChain() {
    for (auto index = chain_.size(); index-- != 0;) {
      const auto* link = &chain_[index];

      if (!charge(inflated_, limits_.inflated_bytes, link->size)) {
        return false;
      }

      resizeForOverwrite(delta_, static_cast<std::size_t>(link->size));
      if (!inflatePacked(inflater_, chunk_.viewMut(), format_, {.pack = packs_[link->pack], .data_offset = link->data_offset, .output = writable(delta_), .whole = true}) || !applyDelta(asBytes(base_), asBytes(delta_), target_, limits_.object_size) ||
          !charge(inflated_, limits_.inflated_bytes, target_.size())) {
        return false;
      }

      std::swap(base_, target_);
    }

    return true;
  }

  Lookup ObjectDatabase::readLoose(const ObjectId& id, ObjectType& type, ds::String<Memory>& output, std::size_t prefix) {
    ds::Array<char, 2 * maximum_hash_size> hex{};
    const auto digits = id.hex(hex.viewMut());
    PathName name;
    if (!name.assign({substring(digits, 0, 2), "/", substring(digits, 2)})) {
      return Lookup::invalid;
    }

    const auto read = readWhole(objects_.get(), name.cString(), compressed_, limits_.object_size);
    if (read != ReadStatus::ok) {
      return read == ReadStatus::missing ? Lookup::missing : Lookup::invalid;
    }

    if (!inflater_.start()) {
      return Lookup::invalid;
    }

    auto& stream = inflater_.stream();
    MemorySource source{asBytes(compressed_)};
    // Room for the longest header, "<type> <size>\0", and the first bytes after it.
    constexpr std::size_t head_bytes = 64;

    ds::Array<std::uint8_t, head_bytes> head{};
    const auto first = pump(stream, source, head.viewMut());
    if (first == Inflated::failed) {
      return Lookup::invalid;
    }

    const auto produced = head.size() - stream.avail_out;
    const auto header = looseHeader(asText(head.view().first(produced)));
    if (!header) {
      return Lookup::invalid;
    }

    type = header->type;
    const auto size = header->size;
    if (prefix == 0 && size > limits_.object_size) {
      return Lookup::invalid;
    }

    const auto wanted = static_cast<std::size_t>(prefix == 0 ? size : std::min<std::uint64_t>(size, prefix));
    if (!charge(inflated_, limits_.inflated_bytes, wanted)) {
      return Lookup::invalid;
    }

    const auto ready = produced - header->length;
    if (ready > size) {
      return Lookup::invalid;
    }

    resizeForOverwrite(output, wanted);
    const auto copied = std::min(ready, wanted);

    std::ranges::copy(head.view().subspan(header->length, copied), writable(output).begin());
    const auto rest = writable(output).subspan(copied);

    if (first == Inflated::ended) {
      return ready == size ? Lookup::found : Lookup::invalid;
    }

    if (wanted < size) {
      return inflatePrefix(stream, source, rest) ? Lookup::found : Lookup::invalid;
    }

    if (rest.empty()) {
      return ready == size && endsHere(stream, source) ? Lookup::found : Lookup::invalid;
    }

    return inflateExactly(stream, source, rest) ? Lookup::found : Lookup::invalid;
  }

  bool ObjectDatabase::charge(std::uint64_t& inflated, std::uint64_t limit, std::uint64_t bytes) noexcept {
    if (bytes > limit - inflated) {
      return false;
    }

    inflated += bytes;
    return true;
  }

  CommitGraph::CommitGraph(Memory& memory) noexcept
      : layers_(memory),
        chain_(memory) {}

  void CommitGraph::load(int objects, ObjectFormat format, const Limits& limits, bool disabled) {
    if (disabled || objects < 0) {
      clear();
      return;
    }

    const auto single = fingerprintAt(objects, "info/commit-graph");
    const auto chain = single.present ? Fingerprint{} : fingerprintAt(objects, "info/commit-graphs/commit-graph-chain");
    if (loaded_ && single == single_ && chain == chain_identity_ && format == format_) {
      return;
    }

    clear();
    loaded_ = true;
    single_ = single;
    chain_identity_ = chain;
    format_ = format;
    if (single.present) {
      if (!addLayer(objects, "info/commit-graph")) {
        layers_.clear();
      }

      return;
    }

    if (!chain.present) {
      return;
    }

    // The chain file's buffer, taken while its lines are read: adding a layer mutates the graph.
    auto listing = std::move(chain_);

    // The chain lists a hash per layer, so it may hold more than one small file.
    constexpr std::size_t chain_small_files = 16;

    if (readWhole(objects, "info/commit-graphs/commit-graph-chain", listing, limits.small_file * chain_small_files) == ReadStatus::ok) {
      std::string_view lines{listing};
      const auto digits = 2 * hashSize(format);

      while (!lines.empty()) {
        const auto end = lines.find('\n');
        const auto line = substring(lines, 0, end);

        lines.remove_prefix(end == std::string_view::npos ? lines.size() : end + 1);
        PathName name;
        if (line.size() != digits || !ObjectId::fromHex(line, format) || layers_.size() >= limits.commit_graph_layers ||
            !name.assign({"info/commit-graphs/graph-", line, ".graph"}) || !addLayer(objects, name.cString())) {
          layers_.clear();
          break;
        }
      }
    }

    chain_ = std::move(listing);
  }

  void CommitGraph::clear() noexcept {
    layers_.clear();
    loaded_ = false;
    single_ = {};
    chain_identity_ = {};
  }

  bool CommitGraph::empty() const noexcept {
    return layers_.empty();
  }

  ds::Option<std::uint32_t> CommitGraph::find(const ObjectId& id) const noexcept {
    const auto hash_size = hashSize(format_);
    if (id.size != hash_size) {
      return ds::none;
    }

    for (const auto& layer : layers_) {
      const auto first = id.bytes[0];
      std::uint32_t low = first == 0 ? 0 : layer.fanout[first - 1];
      std::uint32_t high = layer.fanout[first];

      while (low < high) {
        const auto middle = low + ((high - low) / 2);
        ds::Array<std::uint8_t, maximum_hash_size> name{};
        if (!readAt(layer.file.get(), name.viewMut().first(hash_size), layer.names + (std::uint64_t{middle} * hash_size))) {
          return ds::none;
        }

        const auto order = compareBytes(id.view(), name.view().first(hash_size));
        if (order == 0) {
          return layer.base + middle;
        }

        if (order < 0) {
          high = middle;
        } else {
          low = middle + 1;
        }
      }
    }

    return ds::none;
  }

  ds::Option<ObjectId> CommitGraph::id(std::uint32_t position) const noexcept {
    const auto* layer = layerOf(position);
    const auto hash_size = hashSize(format_);
    ds::Array<std::uint8_t, maximum_hash_size> name{};
    if (layer == nullptr || !readAt(layer->file.get(), name.viewMut().first(hash_size), layer->names + (std::uint64_t{position - layer->base} * hash_size))) {
      return ds::none;
    }

    return ObjectId::fromBytes(name.view().first(hash_size));
  }

  ds::Option<CommitGraph::Commit> CommitGraph::commit(std::uint32_t position) const noexcept {
    const auto* layer = layerOf(position);
    const auto hash_size = hashSize(format_);
    // After the id: the first and second parents, then the generation above the time's high bits,
    // then the time's low bits.
    constexpr std::size_t second_parent_at = 4;
    constexpr std::size_t generation_at = 8;
    constexpr std::size_t time_at = 12;

    ds::Array<std::uint8_t, maximum_hash_size + graph_commit_data_bytes> record{};
    if (layer == nullptr || !readAt(layer->file.get(), record.viewMut().first(hash_size + graph_commit_data_bytes), layer->commits + (std::uint64_t{position - layer->base} * (hash_size + graph_commit_data_bytes)))) {
      return ds::none;
    }

    const auto upper = loadBig32(record.view(), hash_size + generation_at);
    const Commit commit{
        .generation = upper >> graph_generation_shift,
        .time = static_cast<std::int64_t>((std::uint64_t{upper & graph_time_high_mask} << word_bits) | loadBig32(record.view(), hash_size + time_at)),
        .first = loadBig32(record.view(), hash_size),
        .second = loadBig32(record.view(), hash_size + second_parent_at),
        .layer = layer,
    };
    if (commit.generation == 0) {
      return ds::none;
    }

    return commit;
  }

  bool CommitGraph::visitParents(const Commit& commit, std::size_t maximum, void* target, void (*output)(void*, std::uint32_t)) {
    const auto limit = commit.layer->base + commit.layer->count;

    if (commit.first == no_parent) {
      return true;
    }

    if (commit.first >= limit) {
      return false;
    }

    output(target, commit.first);
    if (commit.second == no_parent) {
      return true;
    }

    if ((commit.second & graph_extra_edges) == 0) {
      if (commit.second >= limit) {
        return false;
      }

      output(target, commit.second);
      return true;
    }

    auto edge = std::uint64_t{commit.second & graph_edge_mask};

    for (std::size_t count = 1;; ++count, ++edge) {
      ds::Array<std::uint8_t, graph_edge_bytes> bytes{};
      if (count >= maximum || !fits(commit.layer->edges_size, graph_edge_bytes * edge, graph_edge_bytes) || !readAt(commit.layer->file.get(), bytes.viewMut(), commit.layer->edges + (graph_edge_bytes * edge))) {
        return false;
      }

      const auto value = loadBig32(bytes.view());
      const auto parent = value & graph_edge_mask;
      if (parent >= limit) {
        return false;
      }

      output(target, parent);
      if ((value & graph_last_edge) != 0) {
        return true;
      }
    }
  }

  const CommitGraph::Layer* CommitGraph::layerOf(std::uint32_t position) const noexcept {
    for (const auto& layer : layers_) {
      if (position - layer.base < layer.count) {
        return &layer;
      }
    }

    return nullptr;
  }

  bool CommitGraph::addLayer(int objects, const char* path) {
    const auto hash_size = hashSize(format_);
    Layer layer;
    struct stat status{};
    if (openRegular(objects, path, layer.file, status) != ReadStatus::ok) {
      return false;
    }

    layer.size = static_cast<std::uint64_t>(status.st_size);
    ds::Array<std::uint8_t, graph_header_bytes + (graph_chunk_entry_bytes * (maximum_graph_chunks + 1))> header{};
    if (layer.size < graph_header_bytes + hash_size || !readAt(layer.file.get(), header.viewMut().first(graph_header_bytes), 0)) {
      return false;
    }

    if (asText(header.view().first(graph_signature.size())) != graph_signature || header[graph_version_at] != 1 || header[graph_hash_version_at] != (format_ == ObjectFormat::sha1 ? 1 : graph_sha256_version)) {
      return false;
    }

    const std::size_t chunk_count = header[graph_chunk_count_at];
    const auto table = graph_chunk_entry_bytes * (chunk_count + 1);
    if (header[graph_base_count_at] != layers_.size() || chunk_count > maximum_graph_chunks || !fits(layer.size - hash_size, graph_header_bytes, table) || !readAt(layer.file.get(), header.viewMut().subspan(graph_header_bytes, table), graph_header_bytes)) {
      return false;
    }

    std::uint64_t fanout = 0;
    std::uint64_t fanout_size = 0;
    std::uint64_t names_size = 0;
    std::uint64_t commits_size = 0;

    for (std::size_t chunk = 0; chunk < chunk_count; ++chunk) {
      const auto entry = graph_header_bytes + (graph_chunk_entry_bytes * chunk);
      const auto identifier = loadBig32(header.view(), entry);
      const auto start = loadBig64(header.view(), entry + graph_chunk_id_bytes);
      const auto end = loadBig64(header.view(), entry + graph_chunk_entry_bytes + graph_chunk_id_bytes);
      if (identifier == 0 || start > end || end > layer.size - hash_size) {
        return false;
      }

      switch (identifier) {
      case graph_chunk_fanout:
        fanout = start;
        fanout_size = end - start;
        break;
      case graph_chunk_ids:
        layer.names = start;
        names_size = end - start;
        break;
      case graph_chunk_commits:
        layer.commits = start;
        commits_size = end - start;
        break;
      case graph_chunk_edges:
        layer.edges = start;
        layer.edges_size = end - start;
        break;
      default:
        break;
      }
    }

    ds::Array<std::uint8_t, fanout_entries * sizeof(std::uint32_t)> fanout_bytes{};
    if (loadBig32(header.view(), graph_header_bytes + (graph_chunk_entry_bytes * chunk_count)) != 0 || fanout_size != fanout_bytes.size() || !readAt(layer.file.get(), fanout_bytes.viewMut(), fanout)) {
      return false;
    }

    std::uint32_t previous = 0;

    for (std::size_t index = 0; index < layer.fanout.size(); ++index) {
      layer.fanout.atMut(index) = loadBig32(fanout_bytes.view(), sizeof(std::uint32_t) * index);
      if (layer.fanout[index] < previous) {
        return false;
      }

      previous = layer.fanout[index];
    }

    layer.count = previous;
    layer.base = layers_.empty() ? 0 : layers_.back().base + layers_.back().count;
    if (std::uint64_t{layer.base} + layer.count >= no_parent || names_size != std::uint64_t{layer.count} * hash_size ||
        commits_size != std::uint64_t{layer.count} * (hash_size + graph_commit_data_bytes) || layer.edges_size % graph_edge_bytes != 0) {
      return false;
    }

    layers_.push(std::move(layer));
    return true;
  }

}
