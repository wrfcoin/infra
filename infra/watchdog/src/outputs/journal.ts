import * as fs from 'node:fs';
import * as path from 'node:path';

export interface JournalEntry {
  timestamp: string;
  task: string;
  severity: string;
  llm_model: string | null;
  prompt_tokens: number;
  completion_tokens: number;
  finding: string;
}

export class JournalOutput {
  private dir: string;

  constructor(dir: string) {
    this.dir = dir;
  }

  append(entry: JournalEntry): void {
    try {
      fs.mkdirSync(this.dir, { recursive: true });

      const date = new Date().toISOString().slice(0, 10);
      const filePath = path.join(this.dir, `journal-${date}.jsonl`);

      const line = JSON.stringify(entry) + '\n';
      fs.appendFileSync(filePath, line, 'utf-8');

      console.log(`[journal] Entry appended to ${filePath}`);
    } catch (err) {
      console.error(`[journal] Failed to write: ${(err as Error).message}`);
    }
  }
}
