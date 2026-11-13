local telar = require('telar')

return telar.config {
  api_version = 2,
  runtime = {
    session = { persist = false },
    agents = telar.json.decode([[
      [{
        "name": "fixture-agent",
        "display_name": "Custom Agent",
        "placeholder": "New custom session",
        "icon": "é",
        "process_names": ["fixture-agent"],
        "brand": ["custom agent"],
        "working": ["custom processing"],
        "ready_prompt": ["custom ready"],
        "attachments": "ordered"
      }]
    ]]),
  },
}
