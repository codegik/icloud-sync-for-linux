import path from "path";

export const WATCH_DIR = "/home/codegik/icloud"; // 👈 change this

export const PLAYWRIGHT_STATE_DIR = path.resolve("./playwright-state");
export const PLAYWRIGHT_STATE_FILE = path.resolve(PLAYWRIGHT_STATE_DIR, "storageState.json");

export const DEBOUNCE_MS = 1500;
