import { after, before, describe, it } from 'node:test';
import * as assert from 'node:assert/strict';
import * as http from 'node:http';
import {
  HttpTaskClient,
  type ForecastTask,
  type NodeStatus,
} from './task-client.js';

interface RecordedRequest {
  method: string;
  url: string;
  body: unknown;
  authorization?: string;
}

describe('HttpTaskClient', () => {
  let server: http.Server;
  let baseUrl: string;
  let recordedRequests: RecordedRequest[] = [];

  const rawAvailableTask = {
    taskId: 'weather_model',
    name: 'Weather Model Processing',
    description: 'Run WRF weather forecasting models',
    baseReward: 0.25,
    cpuIntensive: true,
    estimatedTime: '15-30 minutes',
    requirements: { minCPU: 2, minRAM: 4 },
    suitability: 175,
  };

  const availableTask: ForecastTask = {
    ...rawAvailableTask,
    type: 'weather_model',
    inputDataUrl: '',
    configUrl: '',
    submittedBy: 'compute-contribution-server',
    priority: 175,
  };

  before(async () => {
    server = http.createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (chunk) => {
        chunks.push(Buffer.from(chunk));
      });
      req.on('end', () => {
        const rawBody = Buffer.concat(chunks).toString('utf8');
        const body = rawBody ? JSON.parse(rawBody) : null;
        recordedRequests.push({
          method: req.method || 'GET',
          url: req.url || '/',
          body,
          authorization: req.headers.authorization,
        });

        if (req.method === 'POST' && req.url === '/api/compute/register') {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(
            JSON.stringify({
              success: true,
              nodeId: 'compute_mocked',
              capabilities: {
                cpuCount: 8,
                cpuModel: 'Mock CPU',
                totalRAM: 32,
                platform: 'linux',
                architecture: 'x64',
                nodeVersion: 'v20.0.0',
                uptime: 123,
                loadAverage: [0.2, 0.1, 0.1],
              },
              recommendedTasks: [rawAvailableTask],
              estimatedEarnings: {
                hourly: 0.5,
                daily: 12,
              },
            }),
          );
          return;
        }

        if (req.method === 'POST' && req.url === '/api/compute/heartbeat') {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(
            JSON.stringify({
              success: true,
              nodeId: 'compute_mocked',
              nextHeartbeat: Date.now() + 60_000,
              availableTasks: [rawAvailableTask],
              systemHealth: {
                load: 0.2,
                memory: 60,
                uptime: 456,
              },
            }),
          );
          return;
        }

        if (
          req.method === 'GET' &&
          req.url === '/api/compute/tasks/available/compute_mocked'
        ) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(
            JSON.stringify({
              success: true,
              nodeId: 'compute_mocked',
              availableTasks: [rawAvailableTask],
              systemStatus: {
                load: 0.2,
                freeRAM: 20,
                cpuUsage: 10,
              },
            }),
          );
          return;
        }

        if (req.method === 'POST' && req.url === '/api/compute/tasks/start') {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(
            JSON.stringify({
              success: true,
              taskId: 'task_123',
              nodeId: 'compute_mocked',
              task: {
                taskId: 'task_123',
                nodeId: 'compute_mocked',
                taskType: 'weather_model',
                name: availableTask.name,
                description: availableTask.description,
                baseReward: availableTask.baseReward,
                cpuIntensive: availableTask.cpuIntensive,
                estimatedTime: availableTask.estimatedTime,
                requirements: availableTask.requirements,
                status: 'running',
                startTime: new Date(0).toISOString(),
                estimatedCompletion: new Date(60_000).toISOString(),
                progress: 0,
                resourceUsage: {
                  cpu: 15,
                  memory: 25,
                  networkIO: 0,
                },
              },
            }),
          );
          return;
        }

        if (
          req.method === 'GET' &&
          req.url === '/api/compute/tasks/task_123/status'
        ) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(
            JSON.stringify({
              success: true,
              taskId: 'task_123',
              status: 'completed',
              progress: 100,
              resourceUsage: {
                cpu: 22,
                memory: 31,
                networkIO: 1,
              },
              startTime: new Date(0).toISOString(),
              completionTime: new Date(120_000).toISOString(),
              estimatedCompletion: new Date(60_000).toISOString(),
              reward: 0.25,
            }),
          );
          return;
        }

        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: false, error: 'not found' }));
      });
    });

    await new Promise<void>((resolve) => {
      server.listen(0, '127.0.0.1', () => {
        const address = server.address();
        if (!address || typeof address === 'string') {
          throw new Error('Failed to resolve mock server address');
        }

        baseUrl = `http://127.0.0.1:${address.port}`;
        resolve();
      });
    });
  });

  after(async () => {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }

        resolve();
      });
    });
  });

  it('uses the compute contribution API contract end-to-end', async () => {
    recordedRequests = [];
    const operatorToken = 'test-operator-token';

    const client = new HttpTaskClient(baseUrl, operatorToken);
    const nodeStatus: NodeStatus = {
      nodeId: 'compute_mocked',
      status: 'idle',
      uptime: 42,
      tasksCompleted: 0,
      tasksFailed: 0,
      cpuUsage: 12,
      memoryUsageMb: 256,
    };

    const registration = await client.register('wrf-test-wallet', {
      autoStart: true,
      onlyWhenIdle: true,
    });
    assert.ok(registration);
    assert.equal(registration.nodeId, 'compute_mocked');

    const heartbeat = await client.heartbeat('compute_mocked', nodeStatus);
    assert.ok(heartbeat);
    assert.equal(heartbeat.nodeId, 'compute_mocked');
    assert.equal(heartbeat.availableTasks.length, 1);

    const availableTasks = await client.pollAvailableTasks('compute_mocked');
    assert.equal(availableTasks.length, 1);
    assert.equal(availableTasks[0].taskId, 'weather_model');

    const started = await client.startTask('compute_mocked', 'weather_model');
    assert.ok(started);
    assert.equal(started.task.taskType, 'weather_model');

    const status = await client.getTaskStatus('task_123');
    assert.ok(status);
    assert.equal(status.status, 'completed');
    assert.equal(status.reward, 0.25);

    assert.deepEqual(
      recordedRequests.map((request) => ({
        method: request.method,
        url: request.url,
      })),
      [
        { method: 'POST', url: '/api/compute/register' },
        { method: 'POST', url: '/api/compute/heartbeat' },
        {
          method: 'GET',
          url: '/api/compute/tasks/available/compute_mocked',
        },
        { method: 'POST', url: '/api/compute/tasks/start' },
        { method: 'GET', url: '/api/compute/tasks/task_123/status' },
      ],
    );

    assert.deepEqual(
      recordedRequests.map((request) => request.authorization),
      Array(recordedRequests.length).fill(`Bearer ${operatorToken}`),
    );

    assert.deepEqual(recordedRequests[0].body, {
      walletAddress: 'wrf-test-wallet',
      preferences: {
        autoStart: true,
        onlyWhenIdle: true,
      },
    });
    assert.deepEqual(recordedRequests[1].body, {
      nodeId: 'compute_mocked',
      status: nodeStatus,
    });
    assert.deepEqual(recordedRequests[3].body, {
      nodeId: 'compute_mocked',
      taskType: 'weather_model',
    });
  });

  it('returns an empty task list when available-task polling gets a 404', async () => {
    const client = new HttpTaskClient(baseUrl);
    const tasks = await client.pollAvailableTasks('missing-node');
    assert.deepEqual(tasks, []);
  });
});
