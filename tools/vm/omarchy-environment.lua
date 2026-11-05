-- Composited RGBA buffers do not need to support direct scanout on the virtual GPU.
hl.config({
  quirks = {
    skip_non_kms_dmabuf_formats = false,
  },
})

local shell_directory = os.getenv("HOME") .. "/.local/lib/telar-vm/bin"
local command_path = os.getenv("PATH") or "/usr/bin"
local directories = { shell_directory }

for directory in command_path:gmatch("[^:]+") do
  if directory ~= shell_directory then
    table.insert(directories, directory)
  end
end

hl.env("PATH", table.concat(directories, ":"))
