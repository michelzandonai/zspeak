export class FixedWindowRateLimiter {
  #entries = new Map();
  #limit;
  #windowMs;
  #maxEntries;

  constructor({ limit = 10, windowMs = 15 * 60 * 1000, maxEntries = 10_000 } = {}) {
    this.#limit = limit;
    this.#windowMs = windowMs;
    this.#maxEntries = maxEntries;
  }

  consume(key) {
    const now = Date.now();
    if (this.#entries.size >= this.#maxEntries && !this.#entries.has(key)) {
      this.#prune(now);
      if (this.#entries.size >= this.#maxEntries) {
        const earliestReset = Math.min(...Array.from(this.#entries.values(), (entry) => entry.resetAt));
        return {
          allowed: false,
          remaining: 0,
          retryAfterSeconds: Math.max(1, Math.ceil((earliestReset - now) / 1000)),
        };
      }
    }
    const current = this.#entries.get(key);
    const entry = !current || current.resetAt <= now
      ? { count: 0, resetAt: now + this.#windowMs }
      : current;

    entry.count += 1;
    this.#entries.set(key, entry);

    return {
      allowed: entry.count <= this.#limit,
      remaining: Math.max(0, this.#limit - entry.count),
      retryAfterSeconds: Math.max(1, Math.ceil((entry.resetAt - now) / 1000)),
    };
  }

  #prune(now) {
    for (const [key, entry] of this.#entries) {
      if (entry.resetAt <= now) this.#entries.delete(key);
    }
  }
}
