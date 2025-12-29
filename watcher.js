import chokidar from "chokidar";
import { WATCH_DIR, DEBOUNCE_MS } from "./config.js";

export function startWatcher(queue, handler) {
    const lastEvents = new Map();

    function shouldProcess(filePath) {
        const now = Date.now();
        const last = lastEvents.get(filePath) || 0;
        if (now - last < DEBOUNCE_MS) return false;
        lastEvents.set(filePath, now);
        return true;
    }

    const watcher = chokidar.watch(WATCH_DIR, {
        ignoreInitial: true,
        persistent: true,
        depth: Infinity
    });

    watcher.on("add", filePath => {
        if (!shouldProcess(filePath)) return;
        queue.add(() => handler({ type: "add", path: filePath }));
    });

    watcher.on("unlink", filePath => {
        if (!shouldProcess(filePath)) return;
        queue.add(() => handler({ type: "delete", path: filePath }));
    });

    console.log("👀 Watching:", WATCH_DIR);
}
