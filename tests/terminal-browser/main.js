const { ipcMain } = require("electron");
const fs = require("node:fs");

const evidencePath = process.env.TELAR_TERMINAL_BROWSER_EVIDENCE;
ipcMain.on("telar-verification", (_event, evidence) => {
  if (!evidencePath) return;
  fs.appendFileSync(evidencePath, `${JSON.stringify(evidence)}\n`, { mode: 0o600 });
});
