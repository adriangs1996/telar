module telar.plugins;

import telar.tbc;
import std;
import telar.sys.posix;
import telar.base.text.utf8;
import telar.platform.error;
import telar.platform.primitives;
import telar.base.ds;

namespace telar::runtime::plugins {
  namespace {

    auto writeFile(const FileDescriptor& destination, std::string_view bytes) noexcept -> int {
      while (!bytes.empty()) {
        const auto count = ::write(destination.get(), bytes.data(), bytes.size());
        if (count < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (count <= 0) {
          return count == 0 ? EIO : sys::lastError();
        }

        bytes.remove_prefix(static_cast<std::size_t>(count));
      }

      return 0;
    }

    void hashLength(PackageHashing hashing, std::uint64_t length) {
      ds::Array<char, sizeof(length)> encoded;

      for (std::size_t index = 0; index < encoded.size(); ++index) {
        encoded.atMut(index) = static_cast<char>(length & std::numeric_limits<std::uint8_t>::max());
        length >>= std::numeric_limits<std::uint8_t>::digits;
      }

      hashing.update(hashing.hash, {encoded.data(), encoded.size()});
    }

    template <Allocator Memory>
    PackageDigest digest(Memory& memory, int directory, PackageHashing hashing) {
      const PackageFiles files{memory, directory};
      static constexpr char domain[] = "telar-plugin-package-v1";

      hashing.update(hashing.hash, {domain, sizeof(domain)});
      std::size_t total = 0;

      for (const auto& entry : files.entries()) {
        if (entry.directory) {
          continue;
        }

        auto file = openBeneath(directory, entry.path, O_RDONLY);
        const auto bytes = readFileContents(memory, file.get(), PackageLimits::total_bytes - total - 1);

        total += bytes.size();
        hashLength(hashing, entry.path.size());
        hashing.update(hashing.hash, entry.path);
        hashLength(hashing, bytes.size());
        hashing.update(hashing.hash, bytes);
      }

      return hashing.finish(hashing.hash);
    }

    template <Allocator Memory>
    ds::String<Memory> required(ds::String<Memory> path) {
      if (path.empty()) {
        throw std::invalid_argument{"Home directory unavailable for plugins"};
      }

      return path;
    }

    unsigned hex(char byte) {
      if (byte >= '0' && byte <= '9') {
        return static_cast<unsigned>(byte - '0');
      }

      if (byte >= 'a' && byte <= 'f') {
        return static_cast<unsigned>(byte - 'a' + 10);
      }

      if (byte >= 'A' && byte <= 'F') {
        return static_cast<unsigned>(byte - 'A' + 10);
      }

      throw std::invalid_argument{"Invalid plugin digest"};
    }

  }

  // Capabilities

  void Capabilities::insert(Capability capability) {
    if (contains(capability)) {
      throw std::invalid_argument{"DuplicateCapability"};
    }

    bits_ |= bit(capability);
  }

  Capability Capabilities::parseName(std::string_view name) {
    const auto found = std::ranges::find(names_, name);
    if (found == names_.end()) {
      throw std::invalid_argument{"UnknownCapability"};
    }

    return static_cast<Capability>(found - names_.begin());
  }

  std::string_view Capabilities::name(Capability capability) noexcept {
    return names_[static_cast<std::size_t>(capability)];
  }

  template <Allocator Memory>
  Capabilities Capabilities::parse(Memory& memory, const JsonValue& value) {
    Capabilities result;
    ds::String<Memory> text{memory};

    value.eachElement([&](const JsonValue& element) {
      element.string(text);
      result.insert(parseName(text));
    });

    return result;
  }

  // Identity

  bool validEntrypoint(std::string_view path) noexcept {
    if (path.empty() || path.front() == '/') {
      return false;
    }

    for (;;) {
      const auto separator = path.find_first_of("/\\");
      const auto part = path.substr(0, separator);
      if (part.empty() || part == "." || part == "..") {
        return false;
      }

      if (separator == std::string_view::npos) {
        return true;
      }

      path.remove_prefix(separator + 1);
    }
  }

  // Manifest

  template <Allocator Memory>
  struct Manifest::Wire {
    explicit Wire(Memory& memory)
        : id(memory),
          version(memory),
          entry(memory),
          url(memory),
          revision(memory),
          actions(memory),
          capabilities(memory) {}

    void read(Memory& memory, const JsonValue& root) {
      JsonFields fields{memory, root, field_names};

      api_version = number(fields.required("api_version"));
      fields.required("id").string(id);
      fields.required("version").string(version);
      fields.required("entry").string(entry);
      JsonFields origin{memory, fields.required("source"), source_names};

      origin.required("url").string(url);
      origin.required("revision").string(revision);
      for (auto [name, list] : {std::pair{"actions", &actions}, std::pair{"capabilities", &capabilities}}) {
        if (const auto& value = fields.optional(name)) {
          value->eachElement([&](const JsonValue& element) {
            element.string(list->emplace(memory));
          });
        }
      }
    }

    Manifest validate() const {
      constexpr std::uint64_t manifest_api = 1;
      if (api_version != manifest_api) {
        throw std::invalid_argument{"IncompatibleManifestApi"};
      }

      if (!validIdentifier(id) || id.size() > PackageLimits::id_bytes) {
        throw std::invalid_argument{"InvalidPluginId"};
      }

      if (version.empty() || version.size() > PackageLimits::version_bytes) {
        throw std::invalid_argument{"InvalidVersion"};
      }

      if (!validEntrypoint(entry) || entry.size() > PackageLimits::entry_bytes) {
        throw std::invalid_argument{"InvalidEntrypoint"};
      }

      if (url.empty() || url.size() > PackageLimits::source_bytes) {
        throw std::invalid_argument{"InvalidSource"};
      }

      if (revision.empty() || revision.size() > PackageLimits::revision_bytes) {
        throw std::invalid_argument{"InvalidRevision"};
      }

      if (actions.size() > PackageLimits::actions) {
        throw std::invalid_argument{"TooManyActions"};
      }

      Manifest manifest;

      manifest.id.assign(id);
      manifest.version.assign(version);
      manifest.entry.assign(entry);
      manifest.source.assign(url);
      manifest.revision.assign(revision);
      for (const auto& name : actions) {
        if (!validIdentifier(name) || name.size() > PackageLimits::action_bytes) {
          throw std::invalid_argument{"InvalidActionName"};
        }

        for (const auto& previous : std::span{manifest.actions}.first(manifest.action_count)) {
          if (previous.view() == name) {
            throw std::invalid_argument{"DuplicateAction"};
          }
        }

        manifest.actions.atMut(manifest.action_count++).assign(name);
      }

      for (const auto& name : capabilities) {
        manifest.capabilities.insert(Capabilities::parseName(name));
      }

      return manifest;
    }

    // A JSON number as a typed read of a u16 takes it.
    static std::uint64_t number(const JsonValue& value) {
      const auto text = value.encoded();
      if (text.empty() || (text.front() != '-' && (text.front() < '0' || text.front() > '9'))) {
        throw std::invalid_argument{"UnexpectedToken"};
      }

      std::uint16_t result = 0;
      const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
      if (parsed.ec == std::errc::result_out_of_range) {
        throw std::invalid_argument{"Overflow"};
      }

      if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
        throw std::invalid_argument{"InvalidNumber"};
      }

      return result;
    }

    std::uint64_t api_version = 0;
    ds::String<Memory> id;
    ds::String<Memory> version;
    ds::String<Memory> entry;
    ds::String<Memory> url;
    ds::String<Memory> revision;
    ds::Vec<ds::String<Memory>, Memory> actions;
    ds::Vec<ds::String<Memory>, Memory> capabilities;
  };

  // std.json's scanner: input that stops inside a string or an open object or
  // array ran out; anything else malformed is a syntax error.
  const char* Manifest::syntaxFailure(std::string_view text) noexcept {
    std::size_t depth = 0;
    bool in_string = false;
    bool escaped = false;

    for (const char byte : text) {
      if (in_string) {
        escaped = !escaped && byte == '\\';
        in_string = escaped || byte != '"';
      } else if (byte == '"') {
        in_string = true;
      } else if (byte == '{' || byte == '[') {
        ++depth;
      } else if ((byte == '}' || byte == ']') && depth != 0) {
        --depth;
      }
    }

    return in_string || depth != 0 || text.find_first_not_of(" \t\r\n") == std::string_view::npos ? "UnexpectedEndOfInput" : "SyntaxError";
  }

  // std.json's typed-read errors for JsonFields' refusals.
  const char* Manifest::fieldFailure(std::string_view message) noexcept {
    if (message == "Missing JSON field") {
      return "MissingField";
    }

    if (message == "Unknown JSON field") {
      return "UnknownField";
    }

    if (message == "Duplicate JSON field") {
      return "DuplicateField";
    }

    return message.data();
  }

  template <Allocator Memory>
  Manifest Manifest::parse(Memory& memory, std::string_view bytes) {
    if (bytes.size() > PackageLimits::manifest_bytes) {
      throw std::invalid_argument{"ManifestTooLarge"};
    }

    ds::Option<JsonValue> root;

    try {
      validateUtf8(bytes);
      root = JsonValue::parse(bytes);
    } catch (const std::exception&) {
      throw std::invalid_argument{syntaxFailure(bytes)};
    }

    Wire<Memory> wire{memory};

    try {
      wire.read(memory, *root);
    } catch (const JsonError&) {
      throw std::invalid_argument{"UnexpectedToken"};
    } catch (const std::invalid_argument& error) {
      throw std::invalid_argument{fieldFailure(error.what())};
    }

    return wire.validate();
  }

  // Inspection

  void appendInspection(ds::String<Memory>& output, const Package& package) {
    const auto& manifest = package.manifest;

    output.append("id: ");
    output.append(manifest.id.view());
    output.append("\nversion: ");
    output.append(manifest.version.view());
    output.append("\nsource: ");
    output.append(manifest.source.view());
    output.append("\nrevision: ");
    output.append(manifest.revision.view());
    output.append("\ndigest: ");
    appendLowerHex(output, package.digest);
    output.append("\nactions:");
    for (const auto& action : std::span{manifest.actions}.first(manifest.action_count)) {
      output.push(' ');
      output.append(action.view());
    }

    output.append("\ncapabilities:");
    for (unsigned index = 0; index < static_cast<unsigned>(Capability::count); ++index) {
      const auto capability = static_cast<Capability>(index);
      if (manifest.capabilities.contains(capability)) {
        output.push(' ');
        output.append(Capabilities::name(capability));
      }
    }

    output.push('\n');
  }

  // Package files

  template <Allocator Memory>
  PackageFiles<Memory>::PackageFiles(Memory& memory, int directory)
      : memory_(memory),
        entries_(memory) {
    ds::String<Memory> prefix{memory};
    DirectoryStream iterator{directory};

    scan(iterator, prefix);
    std::ranges::sort(entries_.viewMut(), [](const auto& first, const auto& second) {
      return first.path < second.path;
    });
  }

  template <Allocator Memory>
  auto PackageFiles<Memory>::entries() const noexcept -> std::span<const Entry> {
    return entries_;
  }

  template <Allocator Memory>
  void PackageFiles<Memory>::scan(DirectoryStream& iterator, ds::String<Memory>& prefix) {
    const auto directory = iterator.descriptor();
    if (directory < 0) {
      throw SystemError{"Read plugin package directory descriptor"};
    }

    while (const auto* entry = iterator.next()) {
      if (entries_.size() == PackageLimits::files) {
        throw std::invalid_argument{"Too many plugin package entries"};
      }

      struct stat status{};
      if (::fstatat(directory, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        throw SystemError{"Inspect plugin package entry"};
      }

      if (!S_ISREG(status.st_mode) && !S_ISDIR(status.st_mode)) {
        throw std::invalid_argument{"Unsupported plugin package file"};
      }

      const auto parent_length = prefix.size();

#if defined(__APPLE__)
      prefix.append(std::string_view{entry->d_name, entry->d_namlen});
#else
      prefix.append(entry->d_name);
#endif
      if (prefix.size() >= PATH_MAX) {
        throw std::invalid_argument{"Plugin package path exceeds its limit"};
      }

      entries_.push({ds::String<Memory>{memory_, prefix}, S_ISDIR(status.st_mode)});
      if (S_ISDIR(status.st_mode)) {
        FileDescriptor child{::openat(directory, entry->d_name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)};
        if (!child) {
          throw SystemError{"Open plugin package directory"};
        }

        prefix.push('/');
        DirectoryStream children{std::move(child)};

        scan(children, prefix);
      }

      prefix.resize(parent_length);
    }
  }

  // Package copy

  namespace {

    template <Allocator Memory>
    void copyFiles(Memory& memory, const FileDescriptor& source, int destination) {
      const PackageFiles files{memory, source.get()};
      std::size_t total = 0;

      for (const auto& entry : files.entries()) {
        if (entry.directory) {
          if (::mkdirat(destination, entry.path.data(), S_IRWXU) != 0) {
            throw SystemError{"Create plugin package directory"};
          }

          continue;
        }

        auto original = openBeneath(source.get(), entry.path, O_RDONLY);
        const auto contents = readFileContents(memory, original.get(), PackageLimits::total_bytes - total - 1);

        total += contents.size();
        auto copied = openBeneath(destination, entry.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
        const auto error = writeFile(copied, contents);
        if (error != 0) {
          throw SystemError{"Write plugin package file", error};
        }
      }
    }

  }

  template <Allocator Memory>
  Package copyPackage(Memory& memory, const Package& package, int destination, std::string_view path, Package (*inspect)(Memory& memory, std::string_view path)) {
    ds::String<Memory> source_path{memory, package.root.view()};
    FileDescriptor source{telarOpenDirectoryNoFollow(source_path.data())};
    if (!source) {
      throw SystemError{"Open plugin package source"};
    }

    copyFiles(memory, source, destination);

    auto copied = inspect(memory, path);
    if (copied.manifest.id.view() != package.manifest.id.view() || copied.digest != package.digest) {
      throw std::invalid_argument{"Plugin changed while copying its package"};
    }

    return copied;
  }

  // Package inspection

  template <Allocator Memory>
  Package inspectConfiguredPackage(Memory& memory, std::string_view directory, std::string_view path, PackageHashing hashing) {
    ds::String<Memory> resolved{memory, path};

    resolveRelativePath(resolved, directory);
    return inspectPackage(memory, resolved, hashing);
  }

  template <Allocator Memory>
  Package inspectPackage(Memory& memory, std::string_view path, PackageHashing hashing) {
    if (path.empty() || path.size() >= PATH_MAX || path.contains('\0')) {
      throw std::invalid_argument{"Invalid plugin package path"};
    }

    ds::Array<char, PATH_MAX> terminated;

    std::copy(path.begin(), path.end(), terminated.dataMut());
    terminated.atMut(path.size()) = '\0';
    ds::Array<char, PATH_MAX> canonical;
    if (::realpath(terminated.data(), canonical.dataMut()) == nullptr) {
      throw SystemError{"Resolve plugin package"};
    }

    FileDescriptor directory{::open(canonical.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)};
    if (!directory) {
      throw SystemError{"Open plugin package"};
    }

    auto manifest_file = openBeneath(directory.get(), "plugin.json", O_RDONLY);
    const auto source = readFileContents(memory, manifest_file.get(), PackageLimits::manifest_bytes - 1);
    Package package;

    package.root.assign(canonical.data());
    package.manifest = Manifest::parse(memory, source);
    auto entry = openBeneath(directory.get(), package.manifest.entry.view(), O_RDONLY);

    readFileContents(memory, entry.get(), Limits::entry_bytes - 1);
    package.digest = digest(memory, directory.get(), hashing);
    return package;
  }

  // Package installation

  PackageInstallation::PackageInstallation(Memory& memory) noexcept
      : memory_(memory) {}

  void PackageInstallation::install(const Package& package, std::string_view destination) {
    ds::String<Memory> path{memory_, destination};

    resolveAbsolutePath(path);
    if (existing(package, path.data())) {
      return;
    }

    const auto separator = path.view().rfind('/');
    ds::String<Memory> parent{memory_, std::string_view{path}.substr(0, separator)};

    createPrivateDirectory(parent);
    auto directory = openPrivateParent(path);

    parent.append("/.telar-plugin-XXXXXX");
    TemporaryDirectory staging{parent};
    if (::mkdirat(staging.descriptor(), staged_package, 0700) != 0) {
      throw SystemError{"Create plugin installation staging directory"};
    }

    auto copied = openBeneath(staging.descriptor(), staged_package, O_RDONLY | O_DIRECTORY);
    ds::String<Memory> staged_path{memory_, staging.path()};

    staged_path.push('/');
    staged_path.append(staged_package);
    PackageCopy{memory_}.copy(package, copied.get(), staged_path);

    if (renameAt(staging.descriptor(), staged_package, directory.get(), path.data() + separator + 1, RenameMode::create_only) != 0) {
      if (sys::lastError() == EEXIST && existing(package, path.data())) {
        return;
      }

      throw SystemError{"Publish plugin installation"};
    }
  }

  bool PackageInstallation::existing(const Package& package, const char* path) {
    struct stat state{};
    if (::lstat(path, &state) != 0) {
      if (sys::lastError() == ENOENT) {
        return false;
      }

      throw SystemError{"Inspect plugin installation target"};
    }

    if (!S_ISDIR(state.st_mode)) {
      throw std::invalid_argument{"Plugin installation target is not a directory"};
    }

    const auto installed = PackageInspector::inspect(memory_, path);
    if (installed.digest != package.digest) {
      throw std::invalid_argument{"Plugin installation target has a different digest"};
    }

    return true;
  }

  // Specifications

  std::span<const ConfiguredPlugin> Specifications::configured() const noexcept {
    return std::span{entries}.first(count);
  }

  // Package registry

  template <Allocator Memory>
  void registerPackages(ds::Vec<Package, Memory>& packages, Memory& memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications, Package (*inspect)(Memory& memory, std::string_view directory, std::string_view path)) {
    for (const auto& specification : specifications) {
      if (!specification.enabled) {
        continue;
      }

      if (packages.size() == PackageLimits::configured) {
        throw std::invalid_argument{"Too many configured plugins"};
      }

      auto package = inspect(memory, directory, specification.path.view());

      for (const auto& existing : packages) {
        if (existing.manifest.id.view() == package.manifest.id.view()) {
          throw std::invalid_argument{"Duplicate plugin ID"};
        }

        if (stableId(existing.manifest.id.view()) == stableId(package.manifest.id.view())) {
          throw std::invalid_argument{"Plugin ID hash collision"};
        }
      }

      packages.push(std::move(package));
    }
  }

  // Paths

  template <Allocator Memory>
  ds::String<Memory> Paths::trustFile(ds::String<Memory> home) {
    auto path = required(std::move(home));

    path.append("/trust.json");
    return path;
  }

  tbc::view<ds::String<Memory>, tbc::lt::a> Paths::installationDirectory(tbc::view<ds::String<Memory>, tbc::lt::a> data, const Package& package) {
    auto path = required(std::move(data));

    path.append("/telar/plugins/");
    path.append(package.manifest.id.view());
    path.push('/');
    appendLowerHex(path, package.digest);
    return path;
  }

  // Trust store

  std::span<const TrustGrant> TrustStore::grants() const noexcept {
    return std::span{grants_}.first(count_);
  }

  template <Allocator Memory>
  TrustStore TrustStore::load(Memory& memory, std::string_view path) {
    ds::Vec<unsigned char, Memory> bytes{memory};
    if (!readPrivateFile(AT_FDCWD, path, bytes, PackageLimits::trust_bytes - 1)) {
      return {};
    }

    return parse(memory, {reinterpret_cast<const char*>(bytes.data()), bytes.size()});
  }

  template <Allocator Memory>
  TrustStore TrustStore::parse(Memory& memory, std::string_view bytes) {
    validateUtf8(bytes);
    JsonFields root{memory, JsonValue::parse(bytes), root_fields};
    if (!SchemaVersion<Memory>::isOne(memory, root.required("version"))) {
      throw std::invalid_argument{"Incompatible plugin trust store"};
    }

    TrustStore store;

    root.required("grants").eachElement([&](const JsonValue& value) {
      if (store.count_ == PackageLimits::grants) {
        throw std::invalid_argument{"Too many plugin trust grants"};
      }

      JsonFields fields{memory, value, grant_fields};
      auto& grant = store.grants_.atMut(store.count_);

      grant.plugin.assign(fields.string("plugin"));
      if (!validIdentifier(grant.plugin.view())) {
        throw std::invalid_argument{"Invalid trusted plugin ID"};
      }

      for (const auto& existing : std::span{store.grants_}.first(store.count_)) {
        if (existing.plugin.view() == grant.plugin.view()) {
          throw std::invalid_argument{"Duplicate plugin trust grant"};
        }
      }

      grant.digest = parseDigest(fields.string("digest"));
      grant.capabilities = Capabilities::parse(memory, fields.required("capabilities"));
      ++store.count_;
    });

    return store;
  }

  Capabilities TrustStore::granted(std::string_view id, const PackageDigest& digest) const noexcept {
    for (const auto& grant : std::span{grants_}.first(count_)) {
      if (stableId(grant.plugin.view()) == stableId(id) && grant.digest == digest) {
        return grant.capabilities;
      }
    }

    return {};
  }

  void TrustStore::upsert(const Manifest& manifest, const PackageDigest& digest, Capabilities capabilities) {
    for (auto& entry : grants_.viewMut().first(count_)) {
      if (entry.plugin.view() == manifest.id.view()) {
        entry.digest = digest;
        entry.capabilities = capabilities;
        return;
      }
    }

    if (count_ == grants_.size()) {
      throw std::invalid_argument{"Too many plugin trust grants"};
    }

    auto& entry = grants_.atMut(count_++);

    entry.plugin = manifest.id;
    entry.digest = digest;
    entry.capabilities = capabilities;
  }

  bool TrustStore::revoke(std::string_view id) {
    if (!validIdentifier(id)) {
      throw std::invalid_argument{"Invalid plugin ID"};
    }

    for (std::size_t index = 0; index < count_; ++index) {
      if (grants_[index].plugin.view() != id) {
        continue;
      }

      for (std::size_t next = index + 1; next < count_; ++next) {
        grants_.atMut(next - 1) = grants_[next];
      }

      --count_;
      return true;
    }

    return false;
  }

  tbc::view<ds::String<Memory>, tbc::lt::a> TrustStore::json(tbc::view<Memory&, tbc::lt::a> memory) const {
    ds::String<Memory> output{memory, "{\"version\":1,\"grants\":["};

    for (std::size_t index = 0; index < count_; ++index) {
      if (index != 0) {
        output.push(',');
      }

      const auto& entry = grants_[index];

      output.append("{\"plugin\":");
      appendJsonText(output, entry.plugin.view());
      output.append(",\"digest\":\"");
      appendLowerHex(output, entry.digest);
      output.append("\",\"capabilities\":[");
      bool first = true;

      for (unsigned value = 0; value < static_cast<unsigned>(Capability::count); ++value) {
        const auto capability = static_cast<Capability>(value);
        if (entry.capabilities.contains(capability)) {
          if (!first) {
            output.push(',');
          }

          appendJsonText(output, Capabilities::name(capability));
          first = false;
        }
      }

      output.append("]}");
    }

    output.append("]}\n");
    if (output.size() > PackageLimits::trust_bytes) {
      throw std::length_error{"Plugin trust store exceeds its limit"};
    }

    return output;
  }

  PackageDigest TrustStore::parseDigest(std::string_view text) {
    PackageDigest digest;
    if (text.size() != digest.size() * 2) {
      throw std::invalid_argument{"Invalid plugin digest"};
    }

    for (std::size_t index = 0; index < digest.size(); ++index) {
      digest.atMut(index) = static_cast<std::uint8_t>((hex(text[2 * index]) << 4) | hex(text[2 * index + 1]));
    }

    return digest;
  }

  // Trust update

  void saveTrust(Memory& memory, const TrustStore& store, ds::String<Memory> path) {
    const auto contents = store.json(memory);

    resolveAbsolutePath(path);
    const auto separator = path.view().rfind('/');

    createPrivateDirectory(std::string_view{path}.substr(0, separator));
    const auto parent = openPrivateParent(path);
    const auto written = writePrivateFile(parent.get(), std::string_view{path}.substr(separator + 1), {reinterpret_cast<const std::uint8_t*>(contents.data()), contents.size()}, PrivateFileMode::replace);
    if (written != 0) {
      throw SystemError{"Replace plugin trust store", written};
    }
  }

  void updateTrust(Memory& memory, const Package& package, Capabilities capabilities, ds::String<Memory> path) {
    auto store = TrustStore::load(memory, path);

    store.upsert(package.manifest, package.digest, capabilities);
    saveTrust(memory, store, std::move(path));
  }

  void revokeTrust(Memory& memory, std::string_view id, ds::String<Memory> path) {
    auto store = TrustStore::load(memory, path);

    store.revoke(id);
    saveTrust(memory, store, std::move(path));
  }

  // Instantiations

  template Capabilities Capabilities::parse<Memory>(Memory& memory, const JsonValue& value);
  template Capabilities Capabilities::parse<ConcurrentMemory>(ConcurrentMemory& memory, const JsonValue& value);

  template Manifest Manifest::parse<Memory>(Memory& memory, std::string_view bytes);
  template Manifest Manifest::parse<ConcurrentMemory>(ConcurrentMemory& memory, std::string_view bytes);

  template class PackageFiles<Memory>;
  template class PackageFiles<ConcurrentMemory>;

  template Package copyPackage<Memory>(Memory& memory, const Package& package, int destination, std::string_view path, Package (*inspect)(Memory& memory, std::string_view path));
  template Package copyPackage<ConcurrentMemory>(ConcurrentMemory& memory, const Package& package, int destination, std::string_view path, Package (*inspect)(ConcurrentMemory& memory, std::string_view path));

  template Package inspectConfiguredPackage<Memory>(Memory& memory, std::string_view directory, std::string_view path, PackageHashing hashing);
  template Package inspectConfiguredPackage<ConcurrentMemory>(ConcurrentMemory& memory, std::string_view directory, std::string_view path, PackageHashing hashing);
  template Package inspectPackage<Memory>(Memory& memory, std::string_view path, PackageHashing hashing);
  template Package inspectPackage<ConcurrentMemory>(ConcurrentMemory& memory, std::string_view path, PackageHashing hashing);

  template void registerPackages<Memory>(ds::Vec<Package, Memory>& packages, Memory& memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications, Package (*inspect)(Memory& memory, std::string_view directory, std::string_view path));
  template void registerPackages<ConcurrentMemory>(ds::Vec<Package, ConcurrentMemory>& packages, ConcurrentMemory& memory, std::string_view directory, std::span<const ConfiguredPlugin> specifications, Package (*inspect)(ConcurrentMemory& memory, std::string_view directory, std::string_view path));

  template ds::String<Memory> Paths::trustFile<Memory>(ds::String<Memory> home);
  template ds::String<ConcurrentMemory> Paths::trustFile<ConcurrentMemory>(ds::String<ConcurrentMemory> home);

  template TrustStore TrustStore::load<Memory>(Memory& memory, std::string_view path);
  template TrustStore TrustStore::load<ConcurrentMemory>(ConcurrentMemory& memory, std::string_view path);
  template TrustStore TrustStore::parse<Memory>(Memory& memory, std::string_view bytes);
  template TrustStore TrustStore::parse<ConcurrentMemory>(ConcurrentMemory& memory, std::string_view bytes);

}
