export async function ensureLoggedIn(page) {
    await page.goto("https://www.icloud.com/iclouddrive", {
        waitUntil: "domcontentloaded"
    });

    // If login is required, user must do it manually once
    if (page.url().includes("signin")) {
        console.log("⚠️ Please login to iCloud manually (2FA included).");
        console.log("Complete the login and 2FA in the opened browser window; the script will wait until iCloud Drive finishes loading.");
    }

    // Helper: search all frames for the real file input element; supports nested shadowRoots
    async function findFileInputElementHandle(page, timeout = 120000) {
        const deadline = Date.now() + timeout;

        // Try accessibility locator quickly on the page (may work if aria-label exposed)
        try {
            const uploadBtn = page.getByRole('button', { name: 'Upload' });
            await uploadBtn.waitFor({ state: 'visible', timeout: Math.min(3000, timeout) });
            // If the button exposes an input, try to get it via locator
            const input = await uploadBtn.locator('input[type="file"], input.upload-input-element').elementHandle().catch(() => null);
            if (input) return input;
        } catch (e) {
            // fallthrough to frame/shadow search
        }

        while (Date.now() < deadline) {
            const frames = page.frames();
            for (const f of frames) {
                try {
                    // Evaluate in frame to search deep into shadow roots and return the element node when found
                    const handle = await f.evaluateHandle(() => {
                        function deepFind(root) {
                            try {
                                // direct input
                                const direct = root.querySelector && root.querySelector('input.upload-input-element[type="file"]');
                                if (direct) return direct;
                                // host wrapper
                                const host = root.querySelector && (root.querySelector('ui-button.upload-button') || root.querySelector('.upload-button'));
                                if (host) {
                                    // try its shadowRoot and light DOM
                                    if (host.shadowRoot) {
                                        const sInput = host.shadowRoot.querySelector && host.shadowRoot.querySelector('input.upload-input-element[type="file"]');
                                        if (sInput) return sInput;
                                    }
                                    const lInput = host.querySelector && host.querySelector('input.upload-input-element[type="file"]');
                                    if (lInput) return lInput;
                                }
                                // aria-labeled element
                                const aria = root.querySelector && root.querySelector('[aria-label="Upload"]');
                                if (aria) {
                                    const found = aria.querySelector && aria.querySelector('input[type="file"]');
                                    if (found) return found;
                                }
                            } catch (e) {}

                            const elems = root.querySelectorAll ? root.querySelectorAll('*') : [];
                            for (let i = 0; i < elems.length; i++) {
                                const el = elems[i];
                                if (el && el.shadowRoot) {
                                    const r = deepFind(el.shadowRoot);
                                    if (r) return r;
                                }
                            }
                            return null;
                        }
                        return deepFind(document);
                    }).catch(() => null);

                    if (handle && handle.asElement && handle.asElement()) {
                        return handle.asElement();
                    }
                } catch (e) {
                    // ignore and continue to next frame
                }
            }
            await page.waitForTimeout(500);
        }
        return null;
    }

    const elementHandle = await findFileInputElementHandle(page, 120000);
    if (!elementHandle) {
        console.warn('Upload control not found within timeout; uploads may fail.');
    } else {
        // Optionally check visibility, but presence is enough for now
        console.log('✅ iCloud Upload control present');
        // release the handle since caller will reacquire when needed
        try { await elementHandle.dispose(); } catch (e) {}
    }

    console.log("✅ iCloud Drive ready");
}

export async function uploadFile(page, localPath) {
    console.log("⬆️ Uploading:", localPath);

    // Activate Browse if possible
    try {
        const byRole = page.getByRole("treeitem", { name: "Browse" });
        await byRole.waitFor({ state: "visible", timeout: 15000 });
        await byRole.scrollIntoViewIfNeeded();
        await byRole.click({ timeout: 5000 });
    } catch (e) {
        // try CSS fallback
        try {
            const loc = page.locator('li[role="treeitem"]:has-text("Browse"), li.source-list-item:has-text("Browse")').first();
            await loc.waitFor({ state: "visible", timeout: 15000 });
            await loc.scrollIntoViewIfNeeded();
            await loc.click({ timeout: 5000 });
        } catch (e2) {
            console.warn('Could not activate Browse; proceeding to upload input detection.');
        }
    }

    // Find the file input element handle robustly across frames and shadow DOMs
    async function findFileInputElementHandle(page, timeout = 10000) {
        const deadline = Date.now() + timeout;
        while (Date.now() < deadline) {
            const frames = page.frames();
            for (const f of frames) {
                try {
                    const handle = await f.evaluateHandle(() => {
                        function deepFind(root) {
                            try {
                                const direct = root.querySelector && root.querySelector('input.upload-input-element[type="file"]');
                                if (direct) return direct;
                                const host = root.querySelector && (root.querySelector('ui-button.upload-button') || root.querySelector('.upload-button'));
                                if (host) {
                                    if (host.shadowRoot) {
                                        const sInput = host.shadowRoot.querySelector && host.shadowRoot.querySelector('input.upload-input-element[type="file"]');
                                        if (sInput) return sInput;
                                    }
                                    const lInput = host.querySelector && host.querySelector('input.upload-input-element[type="file"]');
                                    if (lInput) return lInput;
                                }
                            } catch (e) {}

                            const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
                            for (let i = 0; i < all.length; i++) {
                                const el = all[i];
                                if (el && el.shadowRoot) {
                                    const r = deepFind(el.shadowRoot);
                                    if (r) return r;
                                }
                            }
                            return null;
                        }
                        return deepFind(document);
                    }).catch(() => null);

                    if (handle && handle.asElement && handle.asElement()) return handle.asElement();
                } catch (e) {
                    // ignore
                }
            }
            await page.waitForTimeout(200);
        }
        return null;
    }

    const elementHandle = await findFileInputElementHandle(page, 10000);
    if (!elementHandle) {
        // final fallback to any file input in main frame
        try {
            const fallback = await page.waitForSelector('input[type="file"]', { timeout: 10000 });
            await fallback.setInputFiles(localPath);
            await page.waitForTimeout(3000);
            return;
        } catch (e) {
            throw new Error('Could not find a file input to upload to');
        }
    }

    // Use the found element handle to set files
    try {
        await elementHandle.setInputFiles(localPath);
        await page.waitForTimeout(3000);
    } finally {
        try { await elementHandle.dispose(); } catch (e) {}
    }
}
