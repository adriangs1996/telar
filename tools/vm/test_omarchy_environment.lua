local directory = assert(arg[0]:match("^(.*[/\\])"), "Run with the script path")
local source = directory .. "omarchy-environment.lua"
local home = "/home/telar-test"
local shell_directory = home .. "/.local/lib/telar-vm/bin"
local cases = {
  { path = "/usr/bin:/bin", expected = shell_directory .. ":/usr/bin:/bin" },
  { path = shell_directory .. ":/usr/bin", expected = shell_directory .. ":/usr/bin" },
  { path = "/bin:" .. shell_directory .. ":/usr/bin:" .. shell_directory, expected = shell_directory .. ":/bin:/usr/bin" },
  { expected = shell_directory .. ":/usr/bin" },
}

for index, case in ipairs(cases) do
  local configuration
  local environment = {}
  local sandbox = {
    hl = {
      config = function(value)
        assert(configuration == nil, "Configure the compositor once")
        configuration = value
      end,
      env = function(name, value)
        environment[name] = value
      end,
    },
    os = {
      getenv = function(name)
        if name == "HOME" then
          return home
        elseif name == "PATH" then
          return case.path
        end
      end,
    },
    table = table,
  }

  assert(loadfile(source, "t", sandbox))()
  assert(configuration and configuration.quirks.skip_non_kms_dmabuf_formats == false,
    "Advertise compositable alpha formats, not only scanout formats")
  assert(environment.PATH == case.expected, "Preserve PATH without duplicate shell wrappers")
  print("environment case " .. index .. " passed")
end
