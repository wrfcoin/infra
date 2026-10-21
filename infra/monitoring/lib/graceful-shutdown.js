/**
 * Graceful shutdown — vendored minimal implementation (infra#725).
 *
 * Both monitoring services required
 * `../../backend/shared/graceful-shutdown/index.js`, a path from the
 * pre-extraction monorepo: `backend/` does not exist in this repo, so both
 * crashed at require() and their images could never have run. The reference
 * implementation lives in wrfcoin/backend `shared/graceful-shutdown/`
 * (last source commit 08e586e70b46) and is ESM; these services are CJS.
 *
 * This vendored copy implements exactly the API surface the two consumers
 * use — `GracefulShutdown.getInstance()`, `registerHandler()`,
 * `setupSignalHandlers()`, and the `ShutdownPriority` constants — with the
 * same semantics: handlers run in ascending priority order, each bounded by
 * its own timeout, and a handler failure never blocks the remaining ones.
 * If the monitoring services ever grow to need the full feature set
 * (events, global timeout), vendor the full module instead of extending this.
 */

'use strict';

const ShutdownPriority = {
  STOP_ACCEPTING_CONNECTIONS: 10,
  DRAIN_HTTP_CONNECTIONS: 20,
  CLOSE_WEBSOCKETS: 30,
  STOP_BACKGROUND_JOBS: 40,
  FLUSH_QUEUES: 50,
  CLOSE_DATABASE: 60,
  CLOSE_CACHE: 70,
  FLUSH_LOGS: 80,
  CLEANUP: 90,
};

const DEFAULT_HANDLER_TIMEOUT_MS = 10000;

let instance = null;

class GracefulShutdown {
  constructor(options = {}) {
    this.handlers = [];
    this.shuttingDown = false;
    this.enableLogging = Boolean(options.enableLogging);
    // options.logger: (message, level) => void — matches the backend module.
    this.logger =
      options.logger ||
      ((message, level) => {
        if (this.enableLogging) {
          // eslint-disable-next-line no-console
          console[level === 'error' ? 'error' : 'log'](`[shutdown] ${message}`);
        }
      });
  }

  static getInstance(options) {
    if (!instance) {
      instance = new GracefulShutdown(options);
    }
    return instance;
  }

  registerHandler({ name, priority, timeout, handler }) {
    if (typeof handler !== 'function') {
      throw new Error(`registerHandler: '${name}' has no handler function`);
    }
    this.handlers.push({
      name: name || `handler-${this.handlers.length}`,
      priority: priority ?? ShutdownPriority.CLEANUP,
      timeout: timeout ?? DEFAULT_HANDLER_TIMEOUT_MS,
      handler,
    });
  }

  async shutdown(signal = 'manual') {
    if (this.shuttingDown) return;
    this.shuttingDown = true;
    this.log(`shutdown started (${signal}), ${this.handlers.length} handlers`);

    const ordered = [...this.handlers].sort((a, b) => a.priority - b.priority);
    for (const entry of ordered) {
      try {
        await Promise.race([
          Promise.resolve(entry.handler()),
          new Promise((_, reject) =>
            setTimeout(
              () => reject(new Error(`timed out after ${entry.timeout}ms`)),
              entry.timeout
            ).unref()
          ),
        ]);
        this.log(`handler '${entry.name}' completed`);
      } catch (error) {
        // A failing handler must not block the rest of the shutdown sequence.
        this.log(`handler '${entry.name}' failed: ${error.message}`, 'error');
      }
    }
    this.log('shutdown complete');
  }

  setupSignalHandlers() {
    for (const signal of ['SIGTERM', 'SIGINT']) {
      process.on(signal, () => {
        this.shutdown(signal).finally(() => process.exit(0));
      });
    }
  }

  log(message, level = 'info') {
    if (this.enableLogging) this.logger(message, level);
  }
}

module.exports = { GracefulShutdown, ShutdownPriority };
