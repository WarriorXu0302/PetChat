import { app, BrowserWindow, ipcMain } from "electron";
import path from "node:path";
import { BackendRegistry } from "@petchat/companion";
import type { Source } from "@petchat/shared";

const isDev = process.env.NODE_ENV === "development";
const COMPANION_ROOT = path.join(__dirname, "..", "..", "..", "..", "packages", "companion");

const registry = new BackendRegistry(COMPANION_ROOT);

let mainWindow: BrowserWindow | null = null;

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1100,
    height: 760,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  if (isDev) {
    mainWindow.loadURL("http://localhost:5173");
    mainWindow.webContents.openDevTools({ mode: "detach" });
  } else {
    mainWindow.loadFile(path.join(__dirname, "..", "renderer", "index.html"));
  }
}

// ---------- IPC ----------

ipcMain.handle("contacts:list", () => registry.listContacts());

ipcMain.handle("contacts:registerFeishu", (_e, slug: string, name: string, chatId: string) => {
  registry.registerFeishu(slug, name, chatId);
  return registry.listContacts();
});

ipcMain.handle(
  "backend:metadata",
  (_e, slug: string, source: Source) => registry.get(slug, source).metadata,
);

ipcMain.handle(
  "backend:history",
  async (_e, slug: string, source: Source, limit: number) =>
    registry.get(slug, source).history(limit ?? 50),
);

ipcMain.on(
  "backend:send",
  async (event, channelId: string, slug: string, source: Source, text: string) => {
    const backend = registry.get(slug, source);
    try {
      for await (const chunk of backend.send(text)) {
        event.sender.send(`backend:stream:${channelId}`, { type: "chunk", chunk });
      }
      event.sender.send(`backend:stream:${channelId}`, { type: "end" });
    } catch (err) {
      event.sender.send(`backend:stream:${channelId}`, {
        type: "error",
        error: (err as Error).message,
      });
    }
  },
);

app.whenReady().then(createWindow);
app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});
