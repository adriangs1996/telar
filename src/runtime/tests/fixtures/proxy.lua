return {
  api_version = 2,
  runtime = {
    session = { persist = false },
    proxy = {
      enabled = true,
      ca_dir = "proxy",
    },
  },
}
