import * as fs from 'node:fs';
import * as path from 'node:path';
// js-yaml v5 is ESM with named exports only — there is no default export, so the
// v4 `import yaml from 'js-yaml'` form throws at startup. See infra#751.
import * as yaml from 'js-yaml';

export interface LLMEndpointConfig {
  endpoint: string;
  model: string;
  max_tokens: number;
  temperature: number;
  timeout_ms: number;
}

export interface LLMConfig {
  primary: LLMEndpointConfig;
  secondary: LLMEndpointConfig | null;
  rate_limit_rpm: number;
}

export interface HealthService {
  name: string;
  url: string;
}

export interface SourcesConfig {
  docker: {
    socket: string;
    container_prefix: string;
    log_window_minutes: number;
  };
  prometheus: {
    url: string;
  };
  health: {
    services: HealthService[];
  };
}

export interface OutputsConfig {
  grafana: {
    url: string;
    api_key: string;
  };
  webhook: {
    url: string | null;
  };
  journal: {
    dir: string;
  };
}

export interface TaskConfig {
  enabled: boolean;
  schedule: string;
  config?: Record<string, unknown>;
}

export interface WatchdogConfig {
  llm: LLMConfig;
  sources: SourcesConfig;
  outputs: OutputsConfig;
  tasks: Record<string, TaskConfig>;
}

export function loadConfig(configPath?: string): WatchdogConfig {
  const resolvedPath = configPath ?? path.resolve(
    process.cwd(),
    'config',
    'watchdog.yaml',
  );

  let config: WatchdogConfig;

  if (fs.existsSync(resolvedPath)) {
    const raw = fs.readFileSync(resolvedPath, 'utf-8');
    config = yaml.load(raw) as WatchdogConfig;
    console.log(`[config] Loaded from ${resolvedPath}`);
  } else {
    console.warn(`[config] Config file not found at ${resolvedPath}, using defaults`);
    config = defaultConfig();
  }

  applyEnvOverrides(config);
  return config;
}

function applyEnvOverrides(config: WatchdogConfig): void {
  if (process.env.LLM_ENDPOINT) {
    config.llm.primary.endpoint = process.env.LLM_ENDPOINT;
  }
  if (process.env.LLM_MODEL) {
    config.llm.primary.model = process.env.LLM_MODEL;
  }
  if (process.env.LLM_MAX_TOKENS) {
    config.llm.primary.max_tokens = parseInt(process.env.LLM_MAX_TOKENS, 10);
  }
  if (process.env.LLM_TEMPERATURE) {
    config.llm.primary.temperature = parseFloat(process.env.LLM_TEMPERATURE);
  }
  if (process.env.LLM_TIMEOUT_MS) {
    config.llm.primary.timeout_ms = parseInt(process.env.LLM_TIMEOUT_MS, 10);
  }
  if (process.env.LLM_RATE_LIMIT_RPM) {
    config.llm.rate_limit_rpm = parseInt(process.env.LLM_RATE_LIMIT_RPM, 10);
  }
  if (process.env.PROMETHEUS_URL) {
    config.sources.prometheus.url = process.env.PROMETHEUS_URL;
  }
  if (process.env.DOCKER_SOCKET) {
    config.sources.docker.socket = process.env.DOCKER_SOCKET;
  }
  if (process.env.GRAFANA_URL) {
    config.outputs.grafana.url = process.env.GRAFANA_URL;
  }
  if (process.env.GRAFANA_API_KEY) {
    config.outputs.grafana.api_key = process.env.GRAFANA_API_KEY;
  }
  if (process.env.WEBHOOK_URL) {
    config.outputs.webhook.url = process.env.WEBHOOK_URL;
  }
  if (process.env.JOURNAL_DIR) {
    config.outputs.journal.dir = process.env.JOURNAL_DIR;
  }
}

function defaultConfig(): WatchdogConfig {
  return {
    llm: {
      primary: {
        endpoint: 'http://localhost:11434/v1',
        model: 'llama3.1:8b',
        max_tokens: 2048,
        temperature: 0.1,
        timeout_ms: 30000,
      },
      secondary: null,
      rate_limit_rpm: 30,
    },
    sources: {
      docker: {
        socket: '/var/run/docker.sock',
        container_prefix: 'wrfcoin-',
        log_window_minutes: 5,
      },
      prometheus: { url: 'http://prometheus:9090' },
      health: { services: [] },
    },
    outputs: {
      grafana: { url: '', api_key: '' },
      webhook: { url: null },
      journal: { dir: '/data/journal' },
    },
    tasks: {},
  };
}
