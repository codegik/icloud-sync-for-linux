import PQueue from "p-queue";

export const queue = new PQueue({
    concurrency: 1,      // important: iCloud UI is not thread-safe
    intervalCap: 5,      // max 5 ops
    interval: 1000       // per second
});
