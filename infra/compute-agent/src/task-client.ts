import { type NodeStatus } from './health.js';

export type { NodeStatus };

export interface ComputeNodePreferences {
  maxCPUUsage?: number;
  maxRAMUsage?: number;
  allowGPU?: boolean;
  preferredTasks?: string[];
  autoStart?: boolean;
  onlyWhenIdle?: boolean;
}

export interface ForecastTask {
  taskId: string;
  type: string;
  inputDataUrl: string;
  configUrl: string;
  submittedBy: string;
  priority: number;
  deadline?: string;
  name: string;
  description: string;
  baseReward: number;
  cpuIntensive: boolean;
  estimatedTime: string;
  requirements: {
    minCPU: number;
    minRAM: number;
  };
  suitability: number;
}

export interface RegisterResult {
  success: boolean;
  nodeId: string;
  capabilities: {
    cpuCount: number;
    cpuModel: string;
    totalRAM: number;
    platform: string;
    architecture: string;
    nodeVersion: string;
    uptime: number;
    loadAverage: number[];
  };
  recommendedTasks: ForecastTask[];
  estimatedEarnings?: {
    hourly: number;
    daily: number;
  };
  message?: string;
}

export interface HeartbeatResult {
  success: boolean;
  nodeId: string;
  nextHeartbeat: number;
  availableTasks: ForecastTask[];
  systemHealth: {
    load: number;
    memory: number;
    uptime: number;
  };
}

export interface StartedTask {
  taskId: string;
  nodeId: string;
  taskType: string;
  name: string;
  description: string;
  baseReward: number;
  cpuIntensive: boolean;
  estimatedTime: string;
  requirements: {
    minCPU: number;
    minRAM: number;
  };
  status: string;
  startTime: string;
  estimatedCompletion: string;
  progress: number;
  resourceUsage: {
    cpu: number;
    memory: number;
    networkIO: number;
  };
}

export interface StartTaskResult {
  success: boolean;
  taskId: string;
  nodeId: string;
  task: StartedTask;
  message?: string;
}

export interface TaskStatusResult {
  success: boolean;
  taskId: string;
  status: string;
  progress: number;
  resourceUsage?: {
    cpu?: number;
    memory?: number;
    networkIO?: number;
  };
  startTime?: string;
  completionTime?: string;
  estimatedCompletion?: string;
  reward?: number;
}

export interface TaskClient {
  register(
    walletAddress: string,
    preferences?: ComputeNodePreferences,
  ): Promise<RegisterResult | null>;
  heartbeat(
    nodeId: string,
    status: NodeStatus,
  ): Promise<HeartbeatResult | null>;
  pollAvailableTasks(nodeId: string): Promise<ForecastTask[]>;
  startTask(nodeId: string, taskType: string): Promise<StartTaskResult | null>;
  getTaskStatus(taskId: string): Promise<TaskStatusResult | null>;
}

export class HttpTaskClient implements TaskClient {
  private baseUrl: string;
  private operatorToken: string;
  private connected: boolean = false;

  constructor(baseUrl: string, operatorToken?: string) {
    this.baseUrl = baseUrl.replace(/\/$/, '');
    this.operatorToken = operatorToken?.trim() || '';
  }

  private normalizeTask(task: {
    taskId: string;
    name: string;
    description: string;
    baseReward: number;
    cpuIntensive: boolean;
    estimatedTime: string;
    requirements: {
      minCPU: number;
      minRAM: number;
    };
    suitability: number;
  }): ForecastTask {
    return {
      taskId: task.taskId,
      type: task.taskId,
      inputDataUrl: '',
      configUrl: '',
      submittedBy: 'compute-contribution-server',
      priority: Math.round(task.suitability),
      name: task.name,
      description: task.description,
      baseReward: task.baseReward,
      cpuIntensive: task.cpuIntensive,
      estimatedTime: task.estimatedTime,
      requirements: task.requirements,
      suitability: task.suitability,
    };
  }

  private async request<T>(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<T | null> {
    const url = `${this.baseUrl}${path}`;
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    };

    if (this.operatorToken) {
      headers.Authorization = `Bearer ${this.operatorToken}`;
    }

    try {
      const res = await fetch(url, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
        signal: AbortSignal.timeout(10_000),
      });

      if (!res.ok) {
        const text = await res.text().catch(() => '');
        console.error(
          `[task-client] ${method} ${path} failed: ${res.status} ${text}`,
        );
        return null;
      }

      if (!this.connected) {
        this.connected = true;
        console.log(`[task-client] Connected to task API at ${this.baseUrl}`);
      }

      const contentType = res.headers.get('content-type') || '';
      if (contentType.includes('application/json')) {
        return (await res.json()) as T;
      }

      return null;
    } catch (err) {
      if (this.connected) {
        console.warn(
          `[task-client] Lost connection to task API: ${(err as Error).message}`,
        );
        this.connected = false;
      } else {
        console.warn(
          `[task-client] Task API unavailable at ${this.baseUrl}: ${(err as Error).message}`,
        );
      }

      return null;
    }
  }

  async register(
    walletAddress: string,
    preferences?: ComputeNodePreferences,
  ): Promise<RegisterResult | null> {
    const result = await this.request<RegisterResult>(
      'POST',
      '/api/compute/register',
      {
        walletAddress,
        ...(preferences ? { preferences } : {}),
      },
    );

    if (result?.success) {
      result.recommendedTasks = result.recommendedTasks.map((task) =>
        this.normalizeTask(task),
      );
      console.log(`[task-client] Registered compute node ${result.nodeId}`);
      return result;
    }

    console.warn('[task-client] Registration failed');
    return null;
  }

  async heartbeat(
    nodeId: string,
    status: NodeStatus,
  ): Promise<HeartbeatResult | null> {
    const result = await this.request<HeartbeatResult>(
      'POST',
      '/api/compute/heartbeat',
      {
        nodeId,
        status,
      },
    );
    if (result?.success) {
      result.availableTasks = result.availableTasks.map((task) =>
        this.normalizeTask(task),
      );
    }
    return result;
  }

  async pollAvailableTasks(nodeId: string): Promise<ForecastTask[]> {
    const result = await this.request<{
      success: boolean;
      availableTasks: ForecastTask[];
    }>('GET', `/api/compute/tasks/available/${encodeURIComponent(nodeId)}`);

    if (!result?.success) {
      return [];
    }

    return result.availableTasks.map((task) => this.normalizeTask(task));
  }

  async startTask(
    nodeId: string,
    taskType: string,
  ): Promise<StartTaskResult | null> {
    return await this.request<StartTaskResult>(
      'POST',
      '/api/compute/tasks/start',
      {
        nodeId,
        taskType,
      },
    );
  }

  async getTaskStatus(taskId: string): Promise<TaskStatusResult | null> {
    return await this.request<TaskStatusResult>(
      'GET',
      `/api/compute/tasks/${encodeURIComponent(taskId)}/status`,
    );
  }
}
