module telar.git;

import std;
import telar.sys.posix;
import telar.base.text;
import telar.base.ds;

namespace telar::git {

  namespace {

    // An index starts with "DIRC", its version and its entry count.
    constexpr std::string_view index_signature = "DIRC";
    constexpr std::size_t index_header_bytes = 12;

    // An entry's ten 32-bit stat fields, then its id and its flags.
    constexpr std::size_t index_stat_bytes = 10 * sizeof(std::uint32_t);

    // An entry's flags: assume-valid, extended, the stage, and the length of its path; then in
    // version 3 the extended flags: skip-worktree and intent-to-add.
    constexpr std::uint16_t assume_valid_flag = 0x8000;
    constexpr std::uint16_t extended_flag = 0x4000;
    constexpr unsigned stage_shift = 12;
    constexpr unsigned stage_mask = 3;
    constexpr std::uint16_t path_length_mask = 0xfff;
    constexpr std::uint16_t skip_worktree_flag = 0x4000;
    constexpr std::uint16_t intent_to_add_flag = 0x2000;
    constexpr std::uint16_t known_extended_flags = skip_worktree_flag | intent_to_add_flag;

    // Versions before 4 pad each entry with NULs to a multiple of eight bytes.
    constexpr std::size_t entry_alignment = 8;

    // An extension: its signature and its size, then its bytes.
    constexpr std::size_t extension_header_bytes = 8;
    constexpr std::size_t extension_signature_bytes = 4;

    // An index entry's bit for an executable file, as the file mode's.
    constexpr std::uint32_t mode_owner_executable = 0100;

    constexpr std::uint32_t file_type_mask = S_IFMT;
    constexpr std::uint32_t owner_executable = S_IXUSR;

    // `field` read whole as a decimal, as std::from_chars reads it: a value out of range reads as 0.
    template <std::integral Integer>
    ds::Option<Integer> wholeNumber(std::string_view field) noexcept {
      Integer value = 0;
      const auto* const end = std::to_address(field.end());
      if (field.empty() || std::from_chars(field.data(), end, value).ptr != end) {
        return ds::none;
      }

      return value;
    }

    // The big-endian fields of an index entry's record, read in order.
    struct RecordReader {
      std::span<const std::uint8_t> bytes;
      std::size_t position = 0;

      std::uint32_t next32() noexcept {
        const auto value = loadBig32(bytes, position);

        position += sizeof(value);
        return value;
      }

      std::uint16_t next16() noexcept {
        const auto value = loadBig16(bytes, position);

        position += sizeof(value);
        return value;
      }

      std::span<const std::uint8_t> next(std::size_t count) noexcept {
        const auto field = bytes.subspan(position, count);

        position += count;
        return field;
      }
    };

    // git's verify_path, reduced to what keeps a path inside the work tree.
    bool validIndexPath(std::string_view path) noexcept {
      if (path.empty() || path.front() == '/' || path.back() == '/') {
        return false;
      }

      std::size_t start = 0;

      for (std::size_t index = 0; index <= path.size(); ++index) {
        if (index != path.size() && path[index] != '/') {
          continue;
        }

        const auto component = substring(path, start, index - start);
        if (component.empty() || component == "." || component == ".." || telar::runtime::asciiEqualIgnoreCase(component, ".git")) {
          return false;
        }

        start = index + 1;
      }

      return true;
    }

    // The prefix-compression length of index v4, encoded like OFS_DELTA offsets.
    bool indexVarint(std::span<const std::uint8_t> data, std::size_t& position, std::uint64_t& value) noexcept {
      if (position >= data.size()) {
        return false;
      }

      auto byte = data[position++];

      value = byte & varint_payload;
      while ((byte & varint_continues) != 0) {
        if (position >= data.size() || value >= maximum_offset_varint) {
          return false;
        }

        byte = data[position++];
        value = ((value + 1) << varint_payload_bits) | (std::uint64_t{byte} & varint_payload);
      }

      return true;
    }

    // The cache-tree child of `parent` named `name`, if the extension has one.
    std::uint32_t cacheTreeChild(const Index& index, std::uint32_t parent, std::string_view name) noexcept {
      if (parent == no_cache_tree) {
        return no_cache_tree;
      }

      const auto tree = index.tree();

      for (auto child = parent + 1; child < tree[parent].end; child = tree[child].end) {
        if (index.treeName(tree[child]) == name) {
          return child;
        }
      }

      return no_cache_tree;
    }

    std::int64_t currentSeconds() noexcept {
      timespec now{};

      ::clock_gettime(CLOCK_REALTIME, &now);
      return static_cast<std::int64_t>(now.tv_sec);
    }

    // The stat data an index entry keeps of a file, truncated to 32 bits as git stores it.
    struct IndexStat {
      std::uint32_t size = 0;
      std::uint32_t modified_seconds = 0;
      std::uint32_t modified_nanoseconds = 0;
      std::uint32_t changed_seconds = 0;
      std::uint32_t changed_nanoseconds = 0;
      std::uint32_t inode = 0;
      std::uint32_t user = 0;
      std::uint32_t group = 0;
    };

    IndexStat indexStat(const struct stat& status, const Fingerprint& file) noexcept {
      return {
          .size = static_cast<std::uint32_t>(status.st_size),
          .modified_seconds = static_cast<std::uint32_t>(file.modified_seconds),
          .modified_nanoseconds = static_cast<std::uint32_t>(file.modified_nanoseconds),
          .changed_seconds = static_cast<std::uint32_t>(file.changed_seconds),
          .changed_nanoseconds = static_cast<std::uint32_t>(file.changed_nanoseconds),
          .inode = static_cast<std::uint32_t>(status.st_ino),
          .user = static_cast<std::uint32_t>(status.st_uid),
          .group = static_cast<std::uint32_t>(status.st_gid),
      };
    }

    // Whether the entry's stat data still describes the file.
    bool statClean(const IndexEntry& entry, const IndexStat& stat) noexcept {
      return entry.size == stat.size && entry.size != 0 && entry.modified_seconds == stat.modified_seconds && entry.modified_nanoseconds == stat.modified_nanoseconds &&
             entry.changed_seconds == stat.changed_seconds && entry.changed_nanoseconds == stat.changed_nanoseconds && entry.inode == stat.inode && entry.user == stat.user &&
             entry.group == stat.group;
    }

    // An entry's record: the index's bytes before their checksum, where the record starts, and the
    // index's version and object format.
    struct EntryRecord {
      std::span<const std::uint8_t> data;
      std::size_t position = 0;
      std::uint32_t version = 0;
      ObjectFormat format = ObjectFormat::sha1;
    };

    // Where an entry's path went in the index's paths, and the position past its record.
    struct EntryPath {
      std::size_t offset = 0;
      std::size_t position = 0;
    };

    // The stat data, id and flags of the entry at `record.position`; the length of its record before
    // its path, or why the index cannot be read.
    std::expected<std::size_t, IndexState> readEntryHeader(const EntryRecord& record, IndexEntry& entry) noexcept {
      const auto end = record.data.size();
      const auto hash_size = hashSize(record.format);
      const auto fixed = index_stat_bytes + hash_size + sizeof(std::uint16_t);
      if (!fits(end, record.position, fixed)) {
        return std::unexpected{IndexState::invalid};
      }

      RecordReader reader{.bytes = record.data, .position = record.position};

      entry.changed_seconds = reader.next32();
      entry.changed_nanoseconds = reader.next32();
      entry.modified_seconds = reader.next32();
      entry.modified_nanoseconds = reader.next32();
      entry.device = reader.next32();
      entry.inode = reader.next32();
      entry.mode = reader.next32();
      entry.user = reader.next32();
      entry.group = reader.next32();
      entry.size = reader.next32();
      entry.id = ObjectId::fromBytes(reader.next(hash_size));
      entry.flags = reader.next16();
      if ((entry.flags & extended_flag) == 0) {
        return fixed;
      }

      if (record.version < 3 || !fits(end, record.position, fixed + sizeof(std::uint16_t))) {
        return std::unexpected{IndexState::invalid};
      }

      entry.extended = reader.next16();
      if ((entry.extended & ~unsigned{known_extended_flags}) != 0) {
        return std::unexpected{IndexState::unsupported};
      }

      return fixed + sizeof(std::uint16_t);
    }

    // The path of a version 4 entry, starting `header` bytes into its record: the bytes it keeps of
    // the previous entry's path, then its own. Appended to `paths`.
    std::expected<EntryPath, IndexState> readCompressedPath(const EntryRecord& record, std::size_t header, const ds::Vec<IndexEntry, Memory>& entries, const Limits& limits, ds::String<Memory>& paths) {
      const auto end = record.data.size();
      const auto previous_offset = entries.empty() ? std::size_t{0} : std::size_t{entries.back().path_offset};
      const auto previous_length = entries.empty() ? std::size_t{0} : std::size_t{entries.back().path_length};
      std::uint64_t strip = 0;
      auto cursor = record.position + header;
      if (!indexVarint(record.data, cursor, strip) || strip > previous_length) {
        return std::unexpected{IndexState::invalid};
      }

      const auto text = asText(record.data);
      const auto terminator = text.find('\0', cursor);
      if (terminator == std::string_view::npos || terminator >= end) {
        return std::unexpected{IndexState::invalid};
      }

      const auto kept = previous_length - static_cast<std::size_t>(strip);
      const auto suffix = substring(text, cursor, terminator - cursor);
      if (kept + suffix.size() > limits.path_length) {
        return std::unexpected{IndexState::invalid};
      }

      const auto offset = paths.size();
      if (offset + kept + suffix.size() > limits.index_file) {
        return std::unexpected{IndexState::invalid};
      }

      // Reserved first, so the kept prefix is copied from a stable buffer.
      paths.reserve(offset + kept + suffix.size());
      paths.append(substring(paths.view(), previous_offset, kept));
      paths.append(suffix);
      return EntryPath{.offset = offset, .position = terminator + 1};
    }

    // The path of a version 2 or 3 entry, starting `header` bytes into its record, which NULs pad to
    // a multiple of eight bytes. Appended to `paths`.
    std::expected<EntryPath, IndexState> readPaddedPath(const EntryRecord& record, std::size_t header, const Limits& limits, ds::String<Memory>& paths) {
      const auto end = record.data.size();
      const auto text = asText(record.data);
      const auto name_start = record.position + header;
      const auto terminator = text.find('\0', name_start);
      if (terminator == std::string_view::npos || terminator >= end) {
        return std::unexpected{IndexState::invalid};
      }

      const auto length = terminator - name_start;
      const auto padded = (header + length + entry_alignment) & ~(entry_alignment - 1);
      if (length > limits.path_length || !fits(end, record.position, padded)) {
        return std::unexpected{IndexState::invalid};
      }

      const auto offset = paths.size();

      paths.append(substring(text, name_start, length));
      return EntryPath{.offset = offset, .position = record.position + padded};
    }

    // The entry at `record.position`, appended to `entries` and its path to `paths`; the position past
    // it, or why the index cannot be read.
    std::expected<std::size_t, IndexState> parseEntry(const EntryRecord& record, const Limits& limits, ds::Vec<IndexEntry, Memory>& entries, ds::String<Memory>& paths) {
      IndexEntry entry{};
      const auto header = readEntryHeader(record, entry);
      if (!header) {
        return std::unexpected{header.error()};
      }

      switch (entry.mode) {
      case mode_file:
      case mode_executable:
      case mode_symlink:
      case mode_gitlink:
        break;
      case mode_directory:
        return std::unexpected{IndexState::unsupported}; // a sparse index directory
      default:
        return std::unexpected{IndexState::invalid};
      }

      const auto read = record.version == 4 ? readCompressedPath(record, *header, entries, limits, paths) : readPaddedPath(record, *header, limits, paths);
      if (!read) {
        return std::unexpected{read.error()};
      }

      const auto path = substring(paths.view(), read->offset);
      if (path.empty()) {
        return std::unexpected{IndexState::unsupported}; // a split index writes replaced entries without names
      }

      const auto declared = std::size_t{entry.flags} & path_length_mask;
      if (paths.size() > std::numeric_limits<std::uint32_t>::max() || (declared < path_length_mask && declared != path.size()) || !validIndexPath(path)) {
        return std::unexpected{IndexState::invalid};
      }

      entry.path_offset = static_cast<std::uint32_t>(read->offset);
      entry.path_length = static_cast<std::uint16_t>(path.size());
      if (!entries.empty()) {
        const auto& previous = entries.back();
        const auto order = substring(paths.view(), previous.path_offset, previous.path_length).compare(path);
        if (order > 0 || (order == 0 && previous.stage() >= entry.stage())) {
          return std::unexpected{IndexState::invalid};
        }
      }

      entries.push(entry);
      return read->position;
    }

    // A cache-tree node read from its record, how many subtrees follow it, and the position past it.
    struct TreeRecord {
      CacheTreeNode node;
      std::uint32_t subtrees = 0;
      std::size_t position = 0;
    };

    // The node at `position` of `data`: "<name>\0<entries> <subtrees>\n", then its id when its entry
    // count is not negative. None when it is malformed.
    ds::Option<TreeRecord> readTreeNode(std::span<const std::uint8_t> data, std::size_t position, ObjectFormat format) noexcept {
      const auto text = asText(data);
      const auto name_end = text.find('\0', position);
      if (name_end == std::string_view::npos) {
        return ds::none;
      }

      TreeRecord record;

      record.node.name_offset = static_cast<std::uint32_t>(position);
      record.node.name_size = static_cast<std::uint32_t>(name_end - position);
      const auto line_end = text.find('\n', name_end + 1);
      if (line_end == std::string_view::npos) {
        return ds::none;
      }

      const auto line = substring(text, name_end + 1, line_end - name_end - 1);
      const auto space = line.find(' ');
      if (space == std::string_view::npos) {
        return ds::none;
      }

      const auto entry_count = wholeNumber<std::int32_t>(substring(line, 0, space));
      const auto subtrees = wholeNumber<std::uint32_t>(substring(line, space + 1));
      if (!entry_count || !subtrees) {
        return ds::none;
      }

      record.node.entries = *entry_count;
      record.subtrees = *subtrees;
      record.position = line_end + 1;
      if (*entry_count < 0) {
        return record;
      }

      const auto hash_size = hashSize(format);
      if (!fits(data.size(), record.position, hash_size)) {
        return ds::none;
      }

      record.node.id = ObjectId::fromBytes(data.subspan(record.position, hash_size));
      record.position += hash_size;
      return record;
    }
  }

  unsigned IndexEntry::stage() const noexcept {
    return (unsigned{flags} >> stage_shift) & stage_mask;
  }

  bool IndexEntry::assumeValid() const noexcept {
    return (flags & assume_valid_flag) != 0;
  }

  bool IndexEntry::skipWorktree() const noexcept {
    return (extended & skip_worktree_flag) != 0;
  }

  bool IndexEntry::intentToAdd() const noexcept {
    return (extended & intent_to_add_flag) != 0;
  }

  Index::Index(Memory& memory) noexcept
      : entries_(memory),
        tree_(memory),
        open_trees_(memory),
        bytes_(memory),
        paths_(memory) {}

  IndexState Index::load(int gitdir, ObjectFormat format, const Limits& limits) {
    const auto identity = fingerprintAt(gitdir, "index");
    if (loaded_ && identity == fingerprint_ && format == format_) {
      return state_;
    }

    loaded_ = true;
    format_ = format;
    entries_.clear();
    tree_.clear();
    paths_.clear();
    fingerprint_ = identity;
    if (!identity.present) {
      state_ = IndexState::ready;
      return state_;
    }

    Fingerprint read_identity;
    const auto read = readWhole(gitdir, "index", bytes_, limits.index_file, &read_identity);
    if (read != ReadStatus::ok) {
      state_ = read == ReadStatus::missing ? IndexState::ready : IndexState::invalid;
      fingerprint_ = read == ReadStatus::missing ? Fingerprint{} : identity;
      return state_;
    }

    fingerprint_ = read_identity;
    state_ = parse(limits);
    if (state_ != IndexState::ready) {
      entries_.clear();
      tree_.clear();
    }

    return state_;
  }

  std::string_view Index::treeName(const CacheTreeNode& node) const noexcept {
    return substring(bytes_.view(), node.name_offset, node.name_size);
  }

  std::string_view Index::path(const IndexEntry& entry) const noexcept {
    return substring(paths_.view(), entry.path_offset, entry.path_length);
  }

  std::int64_t Index::timestamp() const noexcept {
    return fingerprint_.modified_seconds;
  }

  std::span<const IndexEntry> Index::entries() const noexcept {
    return entries_.view();
  }

  std::span<const CacheTreeNode> Index::tree() const noexcept {
    return tree_.view();
  }

  const Fingerprint& Index::fingerprint() const noexcept {
    return fingerprint_;
  }

  IndexState Index::parse(const Limits& limits) {
    const auto hash_size = hashSize(format_);
    const auto data = asBytes(bytes_);
    if (data.size() < index_header_bytes + hash_size || asText(data.first(index_signature.size())) != index_signature) {
      return IndexState::invalid;
    }

    const auto version = loadBig32(data, index_signature.size());
    const auto count = loadBig32(data, index_signature.size() + sizeof(version));

    if (version < 2 || version > 4) {
      return IndexState::unsupported;
    }

    if (count > limits.index_entries) {
      return IndexState::invalid;
    }

    const auto end = data.size() - hash_size;
    const auto checksum = data.subspan(end);
    if (std::ranges::any_of(checksum, [](std::uint8_t byte) {
          return byte != 0;
        })) {
      const auto digest = hashBytes(format_, data.first(end));
      if (!std::ranges::equal(digest.view(), checksum)) {
        return IndexState::invalid;
      }
    }

    entries_.reserve(count);
    std::size_t position = index_header_bytes;

    for (std::uint32_t index = 0; index < count; ++index) {
      const auto parsed = parseEntry({.data = data.first(end), .position = position, .version = version, .format = format_}, limits, entries_, paths_);
      if (!parsed) {
        return parsed.error();
      }

      position = *parsed;
    }

    return parseExtensions(data.first(end), position, limits);
  }

  IndexState Index::parseExtensions(std::span<const std::uint8_t> data, std::size_t position, const Limits& limits) {
    const auto end = data.size();

    while (position < end) {
      if (!fits(end, position, extension_header_bytes)) {
        return IndexState::invalid;
      }

      const auto signature = substring(bytes_.view(), position, extension_signature_bytes);
      const auto size = loadBig32(data, position + extension_signature_bytes);

      position += extension_header_bytes;
      if (!fits(end, position, size)) {
        return IndexState::invalid;
      }

      if (signature == "TREE") {
        const auto parsed = parseTree({.data = data.first(position + size), .position = position, .entries_held = entries_.size(), .format = format_}, limits, tree_, open_trees_);
        if (!parsed || *parsed != position + size) {
          tree_.clear();
        }
      } else if (signature[0] < 'A' || signature[0] > 'Z') {
        return IndexState::unsupported; // a required extension: split index, sparse directories
      }

      position += size;
    }

    return IndexState::ready;
  }

  ds::Option<std::size_t> Index::parseTree(TreeExtension extension, const Limits& limits, ds::Vec<CacheTreeNode, Memory>& tree, ds::Vec<OpenTree, Memory>& open) {
    auto position = extension.position;

    open.clear();
    for (;;) {
      if (open.size() > limits.path_depth || tree.size() >= extension.entries_held + 1 + limits.path_depth) {
        return ds::none;
      }

      const auto record = readTreeNode(extension.data, position, extension.format);
      if (!record) {
        return ds::none;
      }

      position = record->position;
      open.push({.node = static_cast<std::uint32_t>(tree.size()), .remaining = record->subtrees});
      tree.push(record->node);
      // A node ends past its last subtree, and its parent then has one subtree less to read.
      while (!open.empty() && open.back().remaining == 0) {
        tree.atMut(open.back().node).end = static_cast<std::uint32_t>(tree.size());
        open.truncate(open.size() - 1);
        if (!open.empty()) {
          --open.atMut(open.size() - 1).remaining;
        }
      }

      if (open.empty()) {
        return position;
      }
    }
  }

  StagedComparison::StagedComparison(Memory& memory) noexcept
      : trees_(memory),
        memory_(memory) {}

  bool StagedComparison::compare(ObjectDatabase& objects, const Index& index, ds::Option<ObjectId> tree, const Limits& limits, ChangeCounts& counts) {
    Sources sources{.objects = objects, .index = index, .limits = limits, .counts = counts};

    trees_read_ = 0;
    while (trees_.size() < limits.path_depth + 2) {
      trees_.emplace(memory_);
    }

    const auto end = static_cast<std::uint32_t>(index.entries().size());

    if (!tree) {
      addRange(sources, 0, end);
      return true;
    }

    const auto complete = compareTree(sources, *tree, {.end = end, .cache = index.tree().empty() ? no_cache_tree : 0});
    constexpr std::size_t retained = std::size_t{256} << 10U;

    for (auto& buffer : trees_.viewMut()) {
      if (buffer.capacity() > retained) {
        buffer.clear();
        buffer.shrinkToFit();
      }
    }

    return complete;
  }

  std::uint64_t StagedComparison::treesRead() const noexcept {
    return trees_counted_;
  }

  void StagedComparison::resetTreesRead() noexcept {
    trees_counted_ = 0;
  }

  ds::String<Memory>& StagedComparison::buffer(std::size_t depth) noexcept {
    return trees_.atMut(depth);
  }

  bool StagedComparison::readTree(Sources& sources, const ObjectId& id, std::size_t depth) {
    if (++trees_read_ > sources.limits.tree_objects || depth > sources.limits.path_depth) {
      return false;
    }

    ++trees_counted_;
    ObjectType type = ObjectType::none;

    return sources.objects.read(id, type, buffer(depth)) == Lookup::found && type == ObjectType::tree;
  }

  std::string_view StagedComparison::relative(const Index& index, std::uint32_t entry, std::size_t prefix) noexcept {
    return substring(index.path(index.entries()[entry]), prefix);
  }

  void StagedComparison::addRange(Sources& sources, std::uint32_t begin, std::uint32_t end) noexcept {
    const auto entries = sources.index.entries();

    for (auto entry = begin; entry < end; ++entry) {
      const auto& item = entries[entry];
      if (item.stage() == 0 && !item.intentToAdd()) {
        ++sources.counts.staged_added;
      }
    }
  }

  bool StagedComparison::deleteTree(Sources& sources, const ObjectId& id, std::size_t depth) { // NOLINT(misc-no-recursion): a level per directory, which limits.path_depth bounds, each reading its tree into the buffer of its depth
    if (!readTree(sources, id, depth)) {
      return false;
    }

    TreeReader reader{buffer(depth), sources.objects.format()};
    TreeEntry entry;

    while (reader.next(entry)) {
      if (entry.directory()) {
        const auto child = entry.id;
        if (!deleteTree(sources, child, depth + 1)) {
          return false;
        }
      } else {
        ++sources.counts.staged_deleted;
      }
    }

    return !reader.failed();
  }

  bool StagedComparison::compareTree(Sources& sources, const ObjectId& id, Subtree subtree) { // NOLINT(misc-no-recursion): a level per directory, which limits.path_depth bounds, each reading its tree into the buffer of its depth
    if (subtree.cache != no_cache_tree) {
      const auto& node = sources.index.tree()[subtree.cache];
      if (node.entries >= 0 && node.id == id) {
        return true;
      }
    }

    if (!readTree(sources, id, subtree.depth)) {
      return false;
    }

    TreeReader reader{buffer(subtree.depth), sources.objects.format()};
    TreeEntry entry;
    auto current = subtree.begin;

    while (reader.next(entry)) {
      const auto name = entry.name;
      const auto directory = entry.directory();
      const auto tree_id = entry.id;
      const auto aligned = addBefore(sources, subtree, current, name, directory);
      const bool matched = aligned.entry < subtree.end && aligned.order == 0;

      current = aligned.entry;
      if (matched && directory) {
        const auto group_end = groupEnd(sources.index, current, subtree.end, subtree.prefix, name);
        const Subtree child{
            .prefix = subtree.prefix + name.size() + 1,
            .begin = current,
            .end = group_end,
            .cache = cacheTreeChild(sources.index, subtree.cache, name),
            .depth = subtree.depth + 1,
        };
        if (!compareTree(sources, tree_id, child)) {
          return false;
        }

        current = group_end;
      } else if (matched) {
        current = compareFile(sources, subtree, current, entry);
      } else if (directory) {
        if (!deleteTree(sources, tree_id, subtree.depth + 1)) {
          return false;
        }
      } else {
        ++sources.counts.staged_deleted;
      }
    }

    if (reader.failed()) {
      return false;
    }

    addRange(sources, current, subtree.end);
    return true;
  }

  StagedComparison::Aligned StagedComparison::addBefore(Sources& sources, const Subtree& subtree, std::uint32_t current, std::string_view name, bool directory) noexcept {
    int order = 1;

    while (current < subtree.end) {
      const auto rest = relative(sources.index, current, subtree.prefix);
      const auto slash = rest.find('/');
      const auto component = substring(rest, 0, slash);
      const bool nested = slash != std::string_view::npos;

      order = compareTreeNames(component, nested, name, directory);
      if (order >= 0) {
        break;
      }

      const auto group_end = nested ? groupEnd(sources.index, current, subtree.end, subtree.prefix, component) : pathEnd(sources.index, current, subtree.end);

      addRange(sources, current, group_end);
      current = group_end;
    }

    return {.entry = current, .order = order};
  }

  std::uint32_t StagedComparison::compareFile(Sources& sources, const Subtree& subtree, std::uint32_t current, const TreeEntry& entry) noexcept {
    const auto path_end = pathEnd(sources.index, current, subtree.end);
    const auto& item = sources.index.entries()[current];
    if (path_end - current == 1 && item.stage() == 0 && !item.intentToAdd() && (item.mode != entry.mode || item.id != entry.id)) {
      ++sources.counts.staged_modified;
    }

    return path_end;
  }

  std::uint32_t StagedComparison::pathEnd(const Index& index, std::uint32_t begin, std::uint32_t end) noexcept {
    const auto entries = index.entries();
    const auto path = index.path(entries[begin]);
    auto current = begin + 1;

    while (current < end && index.path(entries[current]) == path) {
      ++current;
    }

    return current;
  }

  std::uint32_t StagedComparison::groupEnd(const Index& index, std::uint32_t begin, std::uint32_t end, std::size_t prefix, std::string_view component) noexcept {
    auto current = begin;

    while (current < end) {
      const auto rest = relative(index, current, prefix);
      if (rest.size() <= component.size() || rest[component.size()] != '/' || !rest.starts_with(component)) {
        break;
      }

      ++current;
    }

    return current;
  }

  UnstagedComparison::UnstagedComparison(Memory& memory) noexcept
      : verified_(memory),
        buffer_(memory) {}

  bool UnstagedComparison::compare(int worktree, const Index& index, Options options, const Limits& limits, ChangeCounts& counts) {
    const auto complete = scan(worktree, index, options, limits, counts);

    directories_.reset(-1);
    return complete;
  }

  const UnstagedComparison::Work& UnstagedComparison::work() const noexcept {
    return work_;
  }

  void UnstagedComparison::resetWork() noexcept {
    work_ = {};
  }

  bool UnstagedComparison::scan(int worktree, const Index& index, Options options, const Limits& limits, ChangeCounts& counts) {
    options_ = options;
    hashed_limit_ = limits.hashed_bytes;
    hashed_bytes_ = 0;
    if (index.fingerprint() != verified_index_) {
      verified_.clear();
      verified_index_ = index.fingerprint();
    }

    const auto entries = index.entries();

    if (verified_.size() != entries.size()) {
      verified_.clear();
      verified_.resize(entries.size(), Verified{});
    }

    directories_.reset(worktree);
    for (std::size_t current = 0; current < entries.size(); ++current) {
      const auto& entry = entries[current];
      const auto path = index.path(entry);

      if (entry.stage() != 0) {
        ++counts.conflicted;
        while (current + 1 < entries.size() && index.path(entries[current + 1]) == path) {
          ++current;
        }

        continue;
      }

      if (entry.intentToAdd()) {
        ++counts.intent_to_add;
        continue;
      }

      if (entry.skipWorktree() || entry.assumeValid() || (entry.mode & mode_type_mask) == mode_gitlink) {
        continue;
      }

      ++work_.entries_checked;
      switch (check(index, current, limits)) {
      case Verdict::clean:
        break;
      case Verdict::modified:
        ++counts.unstaged_modified;
        break;
      case Verdict::deleted:
        ++counts.unstaged_deleted;
        break;
      case Verdict::unknown:
        return false;
      }
    }

    return true;
  }

  UnstagedComparison::Verdict UnstagedComparison::check(const Index& index, std::size_t current, const Limits& limits) {
    const auto& entry = index.entries()[current];
    const auto path = index.path(entry);
    const auto slash = path.rfind('/');
    const auto name = slash == std::string_view::npos ? path : substring(path, slash + 1);
    const auto directory = slash == std::string_view::npos ? std::string_view{} : substring(path, 0, slash);
    bool missing = false;
    const auto parent = directories_.open(directory, limits.path_depth, missing);

    if (missing) {
      return Verdict::deleted;
    }

    if (parent < 0) {
      return Verdict::unknown;
    }

    PathName file;
    if (!file.assign({name})) {
      return Verdict::unknown;
    }

    struct stat status{};
    if (::fstatat(parent, file.cString(), &status, AT_SYMLINK_NOFOLLOW) != 0) {
      return sys::lastError() == ENOENT || sys::lastError() == ENOTDIR ? Verdict::deleted : Verdict::unknown;
    }

    // Examined on a copy: examining reads the comparison, so it cannot also write its records.
    auto verified = verified_[current];
    const auto verdict = examine(entry, index.timestamp(), {.parent = parent, .name = file.cString(), .status = status}, verified);

    verified_.atMut(current) = verified;
    return verdict;
  }

  void UnstagedComparison::Directories::reset(int root) noexcept {
    root_ = root;
    for (std::size_t level = 0; level < depth_; ++level) {
      descriptors_.atMut(level).reset();
    }

    depth_ = 0;
    missing_ = no_missing;
  }

  int UnstagedComparison::Directories::open(std::string_view directory, std::size_t maximum_depth, bool& missing) noexcept {
    if (directory.size() > path_.size()) {
      return -1;
    }

    closeFrom(sharedLevels(directory));
    // The kept prefix is already in path_; the rest, from its separator on, is copied.
    const auto copied = depth_ == 0 ? std::size_t{0} : ends_[depth_ - 1];

    std::ranges::copy(substring(directory, copied), path_.viewMut().subspan(copied).begin());
    if (!openFrom(directory, maximum_depth)) {
      return -1;
    }

    if (missing_ != no_missing) {
      missing = true;
      return -1;
    }

    return depth_ == 0 ? root_ : descriptors_[depth_ - 1].get();
  }

  std::size_t UnstagedComparison::Directories::sharedLevels(std::string_view directory) const noexcept {
    std::size_t keep = 0;

    while (keep < depth_) {
      const auto end = ends_[keep];
      if (!directory.starts_with(std::string_view{path_.data(), end}) || (directory.size() > end && directory[end] != '/')) {
        break;
      }

      ++keep;
    }

    return keep;
  }

  void UnstagedComparison::Directories::closeFrom(std::size_t keep) noexcept {
    for (auto level = keep; level < depth_; ++level) {
      descriptors_.atMut(level).reset();
    }

    depth_ = keep;
    if (missing_ != no_missing && missing_ >= depth_) {
      missing_ = no_missing;
    }
  }

  bool UnstagedComparison::Directories::openFrom(std::string_view directory, std::size_t maximum_depth) noexcept {
    auto start = depth_ == 0 ? std::size_t{0} : ends_[depth_ - 1] + 1;

    while (start < directory.size()) {
      if (depth_ >= maximum_depth || depth_ >= descriptors_.size()) {
        return false;
      }

      const auto slash = directory.find('/', start);
      const auto stop = slash == std::string_view::npos ? directory.size() : slash;

      ends_.atMut(depth_) = stop;
      if (missing_ == no_missing && !openLevel(substring(directory, start, stop - start))) {
        return false;
      }

      ++depth_;
      start = stop + 1;
    }

    return true;
  }

  bool UnstagedComparison::Directories::openLevel(std::string_view component) noexcept {
    PathName name;
    if (!name.assign({component})) {
      return false;
    }

    const auto parent = depth_ == 0 ? root_ : descriptors_[depth_ - 1].get();

    descriptors_.atMut(depth_) = openDirectory(parent, name.cString(), FinalLink::refuse);
    if (descriptors_[depth_]) {
      return true;
    }

    if (sys::lastError() != ENOENT && sys::lastError() != ENOTDIR && sys::lastError() != ELOOP) {
      ++depth_;
      return false;
    }

    missing_ = depth_;
    return true;
  }

  UnstagedComparison::Verdict UnstagedComparison::examine(const IndexEntry& entry, std::int64_t index_time, FileAt file, Verified& verified) {
    if (const auto verdict = typeVerdict(entry, file.status)) {
      return *verdict;
    }

    const auto fingerprint = fingerprintOf(file.status);
    const auto stat = indexStat(file.status, fingerprint);
    // Racy as git's is_racy_timestamp: modified within the second the index was written, or later.
    const bool racy = std::cmp_less_equal(index_time, entry.modified_seconds);
    if (statClean(entry, stat) && !racy) {
      return Verdict::clean;
    }

    if (entry.size == 0 && file.status.st_size == 0 && entry.id == emptyBlob(options_.format)) {
      return Verdict::clean;
    }

    if (stat.size != entry.size && entry.size != 0) {
      return Verdict::modified;
    }

    if (verified.valid && verified.file == fingerprint) {
      return verified.modified ? Verdict::modified : Verdict::clean;
    }

    const auto started = currentSeconds();
    const auto type = static_cast<std::uint32_t>(file.status.st_mode) & file_type_mask;
    const ds::Option<ObjectId> content = type == S_IFLNK ? hashLink(file) : hashFile(file);
    if (!content) {
      return Verdict::unknown;
    }

    const bool modified = *content != entry.id;

    // A file modified in the second it was hashed could change again unseen.
    verified = {.file = fingerprint, .modified = modified, .valid = fingerprint.modified_seconds < started && fingerprint.changed_seconds < started};
    return modified ? Verdict::modified : Verdict::clean;
  }

  ds::Option<UnstagedComparison::Verdict> UnstagedComparison::typeVerdict(const IndexEntry& entry, const struct stat& status) const noexcept {
    const auto index_type = entry.mode & mode_type_mask;
    const auto type = static_cast<std::uint32_t>(status.st_mode) & file_type_mask;
    if (type == S_IFDIR) {
      return Verdict::deleted;
    }

    if (index_type == mode_regular) {
      if (type != S_IFREG) {
        return Verdict::modified;
      }

      const bool executable = (static_cast<std::uint32_t>(status.st_mode) & owner_executable) != 0;
      if (options_.file_mode && ((entry.mode & mode_owner_executable) != 0) != executable) {
        return Verdict::modified;
      }

      return ds::none;
    }

    if (index_type == mode_symlink) {
      if (type != S_IFLNK && (type != S_IFREG || options_.symlinks)) {
        return Verdict::modified;
      }

      return ds::none;
    }

    return Verdict::unknown;
  }

  ds::Option<ObjectId> UnstagedComparison::hashLink(FileAt file) {
    // Room for the longest target a symlink in a work tree holds.
    constexpr std::size_t target_capacity = 4096;

    ds::Array<char, target_capacity> target{};
    const auto length = ::readlinkat(file.parent, file.name, target.dataMut(), target.size());
    if (length < 0 || static_cast<std::size_t>(length) >= target.size() || length != file.status.st_size) {
      return ds::none;
    }

    ++work_.files_hashed;
    Hasher hasher{options_.format};

    hashObjectHeader(hasher, "blob", static_cast<std::uint64_t>(length));
    hasher.update(asBytes({target.data(), static_cast<std::size_t>(length)}));
    return hasher.finish();
  }

  ds::Option<ObjectId> UnstagedComparison::hashFile(FileAt file) {
    const auto& expected = file.status;
    const auto size = static_cast<std::uint64_t>(expected.st_size);
    if (size > hashed_limit_ - hashed_bytes_) {
      return ds::none;
    }

    FileDescriptor descriptor;
    struct stat status{};
    if (openRegular(file.parent, file.name, descriptor, status) != ReadStatus::ok || !sameFile(status, expected) || status.st_size != expected.st_size) {
      return ds::none;
    }

    ++work_.files_hashed;
    hashed_bytes_ += size;
    work_.bytes_hashed += size;
    constexpr std::size_t chunk = std::size_t{64} << 10U;
    if (buffer_.size() < chunk) {
      resizeForOverwrite(buffer_, chunk);
    }

    Hasher hasher{options_.format};

    hashObjectHeader(hasher, "blob", size);
    std::uint64_t remaining = size;

    while (remaining != 0) {
      const auto count = ::read(descriptor.get(), buffer_.dataMut(), static_cast<std::size_t>(std::min<std::uint64_t>(remaining, chunk)));
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        return ds::none;
      }

      hasher.update(asBytes({buffer_.data(), static_cast<std::size_t>(count)}));
      remaining -= static_cast<std::uint64_t>(count);
    }

    return hasher.finish();
  }

}
