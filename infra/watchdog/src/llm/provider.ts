import type { LLMEndpointConfig, LLMConfig } from '../config.js';

export interface Message {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface LLMOptions {
  max_tokens?: number;
  temperature?: number;
  timeout_ms?: number;
}

export interface LLMResult {
  content: string;
  model: string;
  prompt_tokens: number;
  completion_tokens: number;
}

export interface LLMProvider {
  chat(messages: Message[], options?: LLMOptions): Promise<LLMResult>;
  isAvailable(): Promise<boolean>;
}

interface ChatCompletionResponse {
  choices: Array<{ message: { content: string } }>;
  model: string;
  usage?: {
    prompt_tokens: number;
    completion_tokens: number;
  };
}

export class OpenAICompatibleProvider implements LLMProvider {
  private endpoint: string;
  private model: string;
  private defaultMaxTokens: number;
  private defaultTemperature: number;
  private defaultTimeoutMs: number;

  constructor(config: LLMEndpointConfig) {
    this.endpoint = config.endpoint.replace(/\/$/, '');
    this.model = config.model;
    this.defaultMaxTokens = config.max_tokens;
    this.defaultTemperature = config.temperature;
    this.defaultTimeoutMs = config.timeout_ms;
  }

  async chat(messages: Message[], options?: LLMOptions): Promise<LLMResult> {
    const url = `${this.endpoint}/chat/completions`;
    const body = JSON.stringify({
      model: this.model,
      messages,
      max_tokens: options?.max_tokens ?? this.defaultMaxTokens,
      temperature: options?.temperature ?? this.defaultTemperature,
    });

    const timeoutMs = options?.timeout_ms ?? this.defaultTimeoutMs;

    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
      signal: AbortSignal.timeout(timeoutMs),
    });

    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new Error(`LLM request failed: ${res.status} ${text}`);
    }

    const data = (await res.json()) as ChatCompletionResponse;
    const choice = data.choices?.[0];
    if (!choice) {
      throw new Error('LLM response contained no choices');
    }

    return {
      content: choice.message.content,
      model: data.model ?? this.model,
      prompt_tokens: data.usage?.prompt_tokens ?? 0,
      completion_tokens: data.usage?.completion_tokens ?? 0,
    };
  }

  async isAvailable(): Promise<boolean> {
    try {
      const url = `${this.endpoint}/models`;
      const res = await fetch(url, {
        signal: AbortSignal.timeout(5000),
      });
      return res.ok;
    } catch {
      return false;
    }
  }
}

export class RetryProvider implements LLMProvider {
  private inner: LLMProvider;
  private maxRetries: number;
  private baseDelayMs: number;

  constructor(inner: LLMProvider, maxRetries = 3, baseDelayMs = 1000) {
    this.inner = inner;
    this.maxRetries = maxRetries;
    this.baseDelayMs = baseDelayMs;
  }

  async chat(messages: Message[], options?: LLMOptions): Promise<LLMResult> {
    let lastError: Error | undefined;

    for (let attempt = 0; attempt <= this.maxRetries; attempt++) {
      try {
        return await this.inner.chat(messages, options);
      } catch (err) {
        lastError = err as Error;
        if (attempt < this.maxRetries) {
          const delay = this.baseDelayMs * Math.pow(2, attempt);
          console.warn(
            `[llm] Attempt ${attempt + 1}/${this.maxRetries + 1} failed: ${lastError.message}. Retrying in ${delay}ms`,
          );
          await sleep(delay);
        }
      }
    }

    throw lastError ?? new Error('LLM request failed after retries');
  }

  async isAvailable(): Promise<boolean> {
    return this.inner.isAvailable();
  }
}

export class RateLimitedProvider implements LLMProvider {
  private inner: LLMProvider;
  private maxRpm: number;
  private timestamps: number[] = [];

  constructor(inner: LLMProvider, maxRpm: number) {
    this.inner = inner;
    this.maxRpm = maxRpm;
  }

  async chat(messages: Message[], options?: LLMOptions): Promise<LLMResult> {
    const now = Date.now();
    const windowStart = now - 60_000;
    this.timestamps = this.timestamps.filter((t) => t > windowStart);

    if (this.timestamps.length >= this.maxRpm) {
      throw new Error(
        `LLM rate limit exceeded: ${this.maxRpm} requests/minute`,
      );
    }

    this.timestamps.push(now);
    return this.inner.chat(messages, options);
  }

  async isAvailable(): Promise<boolean> {
    return this.inner.isAvailable();
  }
}

export class FallbackProvider implements LLMProvider {
  private primary: LLMProvider;
  private secondary: LLMProvider | null;

  constructor(primary: LLMProvider, secondary: LLMProvider | null) {
    this.primary = primary;
    this.secondary = secondary;
  }

  async chat(messages: Message[], options?: LLMOptions): Promise<LLMResult> {
    try {
      return await this.primary.chat(messages, options);
    } catch (primaryErr) {
      if (!this.secondary) {
        throw primaryErr;
      }
      console.warn(
        `[llm] Primary failed: ${(primaryErr as Error).message}. Trying secondary.`,
      );
      return this.secondary.chat(messages, options);
    }
  }

  async isAvailable(): Promise<boolean> {
    if (await this.primary.isAvailable()) return true;
    if (this.secondary) return this.secondary.isAvailable();
    return false;
  }
}

export function createProvider(config: LLMConfig): LLMProvider {
  const primary = new RateLimitedProvider(
    new RetryProvider(new OpenAICompatibleProvider(config.primary)),
    config.rate_limit_rpm,
  );

  const secondary = config.secondary
    ? new RateLimitedProvider(
        new RetryProvider(new OpenAICompatibleProvider(config.secondary)),
        config.rate_limit_rpm,
      )
    : null;

  return new FallbackProvider(primary, secondary);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
