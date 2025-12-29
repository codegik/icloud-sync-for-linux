import { queue } from "./queue.js";
import { startWorker } from "./worker.js";
import { startWatcher } from "./watcher.js";

(async () => {
    const handler = await startWorker(queue);
    startWatcher(queue, handler);
})();
