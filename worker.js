import {chromium} from "playwright";
import fs from "fs";
import {PLAYWRIGHT_STATE_DIR, PLAYWRIGHT_STATE_FILE} from "./config.js";
import {ensureLoggedIn, uploadFile} from "./icloud.js";

function ensureDir(dir) {
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, {recursive: true});
}

export async function startWorker(queue) {
    ensureDir(PLAYWRIGHT_STATE_DIR);

    const hasState = fs.existsSync(PLAYWRIGHT_STATE_FILE);

    const browser = await chromium.launch({
        headless: false
    });

    const context = await browser.newContext({
        storageState: hasState ? PLAYWRIGHT_STATE_FILE : undefined
    });

    const page = await context.newPage();

    // No state or valid state — ensure login and persist
    await ensureLoggedIn(page);
    await context.storageState({path: PLAYWRIGHT_STATE_FILE});

    return createProcessor(queue, page);
}

function createProcessor(queue, page) {
    queue.on("add", () => {
        console.log("📥 Queue size:", queue.size);
    });

    return async function processEvent(event) {
        if (event.type === "add") {
            await uploadFile(page, event.path);
        }
    };
}
