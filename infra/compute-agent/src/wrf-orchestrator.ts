import Docker from 'dockerode';
import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import * as crypto from 'node:crypto';
import * as os from 'node:os';
import { type ForecastTask } from './task-client.js';
import { type StorageClient } from './storage-client.js';

export interface WrfResult {
  outputPath: string;
  outputHash: string;
  executionTimeMs: number;
  modelVersion: string;
}

const WPS_IMAGE = process.env.WPS_IMAGE || 'wrfcoin/wps:latest';
const WRF_IMAGE = process.env.WRF_IMAGE || 'wrfcoin/wrf:latest';
const WORK_BASE = process.env.WORK_DIR || '/work';

export class WrfOrchestrator {
  private docker: Docker;
  private storageClient: StorageClient;

  constructor(storageClient: StorageClient) {
    this.docker = new Docker({ socketPath: '/var/run/docker.sock' });
    this.storageClient = storageClient;
  }

  /**
   * Run a full WRF forecast pipeline for the given task.
   *
   * Steps:
   *  1. Create a temporary working directory
   *  2. Download input data (GFS/GRIB) and config files (namelist.wps, namelist.input)
   *  3. Run WPS container: geogrid -> ungrib -> metgrid
   *  4. Run WRF container: real.exe -> wrf.exe
   *  5. Collect and hash output files
   *  6. Return result metadata
   */
  async runForecast(task: ForecastTask): Promise<WrfResult> {
    const startTime = Date.now();
    const workDir = path.join(
      WORK_BASE,
      `task-${task.taskId}-${Date.now()}`,
    );

    console.log(
      `[wrf] Starting forecast for task ${task.taskId} in ${workDir}`,
    );

    await fs.mkdir(workDir, { recursive: true });
    const inputDir = path.join(workDir, 'input');
    const outputDir = path.join(workDir, 'output');
    const wpsDir = path.join(workDir, 'wps');
    await fs.mkdir(inputDir, { recursive: true });
    await fs.mkdir(outputDir, { recursive: true });
    await fs.mkdir(wpsDir, { recursive: true });

    try {
      // Step 1: Download input data and config
      console.log(`[wrf] Downloading input data from ${task.inputDataUrl}`);
      const inputData = await this.storageClient.downloadInput(
        task.inputDataUrl,
      );
      const inputPath = path.join(inputDir, 'input.grib2');
      await fs.writeFile(inputPath, inputData);

      console.log(`[wrf] Downloading config from ${task.configUrl}`);
      const configData = await this.storageClient.downloadInput(task.configUrl);
      const configStr = configData.toString('utf-8');

      // Parse config: expects JSON with namelist_wps and namelist_input fields
      let namelistWps: string;
      let namelistInput: string;
      try {
        const config = JSON.parse(configStr) as {
          namelist_wps: string;
          namelist_input: string;
        };
        namelistWps = config.namelist_wps;
        namelistInput = config.namelist_input;
      } catch {
        // If not JSON, assume it's a single namelist.input and use a default WPS config
        namelistWps = configStr;
        namelistInput = configStr;
      }

      await fs.writeFile(path.join(wpsDir, 'namelist.wps'), namelistWps);
      await fs.writeFile(path.join(workDir, 'namelist.input'), namelistInput);

      // Step 2: Run WPS (geogrid -> ungrib -> metgrid)
      console.log(`[wrf] Running WPS pipeline...`);
      await this.runContainer(WPS_IMAGE, 'wps', {
        binds: [
          `${inputDir}:/input:ro`,
          `${wpsDir}:/wps:rw`,
          `${outputDir}:/output:rw`,
        ],
        env: ['WPS_STAGE=all'],
        taskId: task.taskId,
      });

      // Step 3: Run WRF (real.exe -> wrf.exe)
      console.log(`[wrf] Running WRF model...`);
      await this.runContainer(WRF_IMAGE, 'wrf', {
        binds: [
          `${wpsDir}:/wps:ro`,
          `${workDir}/namelist.input:/wrf/namelist.input:ro`,
          `${outputDir}:/output:rw`,
        ],
        env: ['WRF_STAGE=all'],
        taskId: task.taskId,
      });

      // Step 4: Collect output and compute hash
      const outputFiles = await fs.readdir(outputDir);
      const wrfOutputs = outputFiles.filter(
        (f) => f.startsWith('wrfout_') || f.endsWith('.nc'),
      );

      if (wrfOutputs.length === 0) {
        throw new Error('No WRF output files produced');
      }

      // Use the first output file (primary domain)
      const primaryOutput = path.join(outputDir, wrfOutputs[0]);
      const outputContent = await fs.readFile(primaryOutput);
      const outputHash = crypto
        .createHash('sha256')
        .update(outputContent)
        .digest('hex');

      const executionTimeMs = Date.now() - startTime;
      console.log(
        `[wrf] Forecast complete for task ${task.taskId} in ${Math.round(executionTimeMs / 1000)}s, hash: ${outputHash.slice(0, 16)}...`,
      );

      // Detect model version from container image labels
      const modelVersion = await this.getModelVersion();

      return {
        outputPath: primaryOutput,
        outputHash,
        executionTimeMs,
        modelVersion,
      };
    } catch (err) {
      const executionTimeMs = Date.now() - startTime;
      console.error(
        `[wrf] Forecast failed for task ${task.taskId} after ${Math.round(executionTimeMs / 1000)}s: ${(err as Error).message}`,
      );
      throw err;
    }
  }

  private async runContainer(
    image: string,
    name: string,
    opts: { binds: string[]; env: string[]; taskId: string },
  ): Promise<void> {
    const containerName = `wrfcoin-${name}-${opts.taskId}-${Date.now()}`;

    // Pull image if not available locally
    try {
      await this.docker.getImage(image).inspect();
    } catch {
      console.log(`[wrf] Pulling image ${image}...`);
      const stream = await this.docker.pull(image);
      await new Promise<void>((resolve, reject) => {
        this.docker.modem.followProgress(
          stream,
          (err: Error | null) => (err ? reject(err) : resolve()),
        );
      });
    }

    const container = await this.docker.createContainer({
      Image: image,
      name: containerName,
      Env: opts.env,
      HostConfig: {
        Binds: opts.binds,
        Memory: 4 * 1024 * 1024 * 1024, // 4GB memory limit
        NanoCpus: 4_000_000_000, // 4 CPUs
      },
      Labels: {
        'wrfcoin.task-id': opts.taskId,
        'wrfcoin.component': name,
      },
    });

    await container.start();
    console.log(`[wrf] Container ${containerName} started`);

    // Wait for container to finish
    const { StatusCode } = await container.wait();

    if (StatusCode !== 0) {
      // Fetch logs before removing the container so errors are not lost
      let logs = '';
      try {
        const logStream = await container.logs({
          stdout: true,
          stderr: true,
          tail: 50,
        });
        logs = logStream.toString();
      } catch {
        // Log retrieval failed — continue with removal
      }

      // Remove the failed container after capturing logs
      try {
        await container.remove({ force: true });
      } catch {
        // Best-effort removal
      }

      throw new Error(
        `Container ${containerName} exited with status ${StatusCode}${logs ? `\n${logs}` : ''}`,
      );
    }

    // Remove the container after successful completion
    try {
      await container.remove();
    } catch {
      // Best-effort removal
    }

    console.log(`[wrf] Container ${containerName} completed successfully`);
  }

  private async getModelVersion(): Promise<string> {
    try {
      const image = await this.docker.getImage(WRF_IMAGE).inspect();
      return (
        image.Config?.Labels?.['wrfcoin.wrf-version'] || 'WRF-ARW-unknown'
      );
    } catch {
      return 'WRF-ARW-unknown';
    }
  }

  async cleanup(workDir: string): Promise<void> {
    try {
      await fs.rm(workDir, { recursive: true, force: true });
      console.log(`[wrf] Cleaned up working directory ${workDir}`);
    } catch (err) {
      console.warn(
        `[wrf] Failed to clean up ${workDir}: ${(err as Error).message}`,
      );
    }
  }
}
