// Checkpoint store — conversation + git-tracked file snapshots under .jackal/checkpoints/.

import { execSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import type { AgentMessage } from "@earendil-works/pi-agent-core";

const MAX_CHECKPOINT_FILES = 500;
const DESCRIPTION_LENGTH = 80;

export interface CheckpointMetadata {
  name: string;
  timestamp: string;
  messageCount: number;
  filesChanged: string[];
  provider: { name: string; model: string };
  description?: string;
  gitCommitHash?: string;
}

export interface CheckpointConversation {
  messages: AgentMessage[];
}

export interface CheckpointData {
  metadata: CheckpointMetadata;
  conversation: CheckpointConversation;
  fileSnapshots: Map<string, string>;
}

export interface CheckpointListItem {
  name: string;
  metadata: CheckpointMetadata;
  sizeBytes?: number;
}

export interface CreateCheckpointInput {
  name?: string;
  messages: AgentMessage[];
  provider: string;
  model: string;
  modifiedFiles?: string[];
}

export interface LoadCheckpointOptions {
  restoreConversation?: boolean;
  createBackup?: boolean;
}

export function checkpointsDir(cwd: string): string {
  return join(cwd, ".jackal", "checkpoints");
}

export function validateCheckpointName(name: string): { valid: boolean; error?: string } {
  if (!name || name.trim().length === 0) {
    return { valid: false, error: "Checkpoint name cannot be empty" };
  }
  if (name.length > 100) {
    return { valid: false, error: "Checkpoint name must be 100 characters or less" };
  }
  if (/[<>:"/\\|?*]/.test(name)) {
    return { valid: false, error: "Checkpoint name contains invalid characters" };
  }
  if (
    name.startsWith(".") ||
    name.endsWith(".") ||
    name.startsWith(" ") ||
    name.endsWith(" ")
  ) {
    return { valid: false, error: "Checkpoint name cannot start or end with a dot or space" };
  }
  return { valid: true };
}

function generateCheckpointName(): string {
  const timestamp = new Date()
    .toISOString()
    .replace(/[:.]/g, "-")
    .replace("T", "-")
    .split(".")[0];
  return `checkpoint-${timestamp}`;
}

function checkpointPath(cwd: string, name: string): string {
  return join(checkpointsDir(cwd), name);
}

function generateDescription(messages: AgentMessage[]): string {
  for (const msg of messages) {
    const role = (msg as { role?: string }).role;
    const content = (msg as { content?: unknown }).content;
    if (role === "user" && typeof content === "string" && content.trim()) {
      const text = content.trim();
      return text.length > DESCRIPTION_LENGTH
        ? `${text.slice(0, DESCRIPTION_LENGTH)}...`
        : text;
    }
  }
  return "Empty conversation";
}

function gitCommitHash(cwd: string): string | undefined {
  try {
    return execSync("git rev-parse HEAD", {
      cwd,
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return undefined;
  }
}

/** Git-tracked modified + untracked (non-ignored) files. */
export function getModifiedFiles(cwd: string): string[] {
  try {
    const modifiedOutput = execSync("git diff --name-only HEAD", {
      cwd,
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();

    const untrackedOutput = execSync("git ls-files --others --exclude-standard", {
      cwd,
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();

    const modifiedFiles = modifiedOutput ? modifiedOutput.split("\n").filter(Boolean) : [];
    const untrackedFiles = untrackedOutput ? untrackedOutput.split("\n").filter(Boolean) : [];
    const allFiles = [...new Set([...modifiedFiles, ...untrackedFiles])];

    if (allFiles.length > MAX_CHECKPOINT_FILES) {
      return allFiles.slice(0, MAX_CHECKPOINT_FILES);
    }
    return allFiles;
  } catch {
    return [];
  }
}

async function captureFiles(cwd: string, filePaths: string[]): Promise<Map<string, string>> {
  const snapshots = new Map<string, string>();

  for (const filePath of filePaths) {
    try {
      const absolutePath = resolve(cwd, filePath);
      const content = await readFile(absolutePath, "utf-8");
      const rel = relative(cwd, absolutePath).split("\\").join("/");
      snapshots.set(rel, content);
    } catch {
      /* skip unreadable files */
    }
  }

  return snapshots;
}

async function ensureCheckpointsDir(cwd: string): Promise<void> {
  await mkdir(checkpointsDir(cwd), { recursive: true });
}

async function dirSize(dirPath: string): Promise<number> {
  let total = 0;
  try {
    const entries = await readdir(dirPath, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = join(dirPath, entry.name);
      if (entry.isDirectory()) {
        total += await dirSize(fullPath);
      } else {
        const s = await stat(fullPath);
        total += s.size;
      }
    }
  } catch {
    /* ignore */
  }
  return total;
}

export async function createCheckpoint(
  cwd: string,
  input: CreateCheckpointInput,
): Promise<CheckpointMetadata> {
  await ensureCheckpointsDir(cwd);

  const checkpointName = input.name?.trim() || generateCheckpointName();
  const validation = validateCheckpointName(checkpointName);
  if (!validation.valid) {
    throw new Error(validation.error ?? "Invalid checkpoint name");
  }

  const dir = checkpointPath(cwd, checkpointName);
  if (existsSync(dir)) {
    throw new Error(`Checkpoint '${checkpointName}' already exists`);
  }

  const filesToSnapshot = input.modifiedFiles ?? getModifiedFiles(cwd);
  const fileSnapshots = await captureFiles(cwd, filesToSnapshot);

  const metadata: CheckpointMetadata = {
    name: checkpointName,
    timestamp: new Date().toISOString(),
    messageCount: input.messages.length,
    filesChanged: [...fileSnapshots.keys()],
    provider: { name: input.provider, model: input.model },
    description: generateDescription(input.messages),
    gitCommitHash: gitCommitHash(cwd),
  };

  const conversation: CheckpointConversation = {
    messages: structuredClone(input.messages),
  };

  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, "metadata.json"), JSON.stringify(metadata, null, 2) + "\n", "utf-8");
  await writeFile(
    join(dir, "conversation.json"),
    JSON.stringify(conversation, null, 2) + "\n",
    "utf-8",
  );

  if (fileSnapshots.size > 0) {
    const filesDir = join(dir, "files");
    await mkdir(filesDir, { recursive: true });
    for (const [relPath, content] of fileSnapshots) {
      const filePath = join(filesDir, relPath);
      await mkdir(dirname(filePath), { recursive: true });
      await writeFile(filePath, content, "utf-8");
    }
  }

  return metadata;
}

export async function loadCheckpoint(cwd: string, name: string): Promise<CheckpointData> {
  const dir = checkpointPath(cwd, name);
  if (!existsSync(dir)) {
    throw new Error(`Checkpoint '${name}' does not exist`);
  }

  const metadata = JSON.parse(
    await readFile(join(dir, "metadata.json"), "utf-8"),
  ) as CheckpointMetadata;

  const conversation = JSON.parse(
    await readFile(join(dir, "conversation.json"), "utf-8"),
  ) as CheckpointConversation;

  const fileSnapshots = new Map<string, string>();
  const filesDir = join(dir, "files");
  if (existsSync(filesDir)) {
    for (const relPath of metadata.filesChanged) {
      try {
        const content = await readFile(join(filesDir, relPath), "utf-8");
        fileSnapshots.set(relPath, content);
      } catch {
        /* skip missing snapshots */
      }
    }
  }

  return { metadata, conversation, fileSnapshots };
}

export async function listCheckpoints(cwd: string): Promise<CheckpointListItem[]> {
  await ensureCheckpointsDir(cwd);

  const entries = await readdir(checkpointsDir(cwd));
  const checkpoints: CheckpointListItem[] = [];

  for (const entry of entries) {
    const dir = join(checkpointsDir(cwd), entry);
    try {
      const s = await stat(dir);
      if (!s.isDirectory()) continue;

      const metadataPath = join(dir, "metadata.json");
      if (!existsSync(metadataPath)) continue;

      const metadata = JSON.parse(await readFile(metadataPath, "utf-8")) as CheckpointMetadata;
      checkpoints.push({
        name: entry,
        metadata,
        sizeBytes: await dirSize(dir),
      });
    } catch {
      /* skip corrupt entries */
    }
  }

  checkpoints.sort(
    (a, b) =>
      new Date(b.metadata.timestamp).getTime() - new Date(a.metadata.timestamp).getTime(),
  );

  return checkpoints;
}

export async function deleteCheckpoint(cwd: string, name: string): Promise<void> {
  const dir = checkpointPath(cwd, name);
  if (!existsSync(dir)) {
    throw new Error(`Checkpoint '${name}' does not exist`);
  }
  await rm(dir, { recursive: true, force: true });
}

export async function restoreCheckpointFiles(
  cwd: string,
  snapshots: Map<string, string>,
): Promise<void> {
  const errors: string[] = [];

  for (const [relPath, content] of snapshots) {
    try {
      const absolutePath = resolve(cwd, relPath);
      await mkdir(dirname(absolutePath), { recursive: true });
      await writeFile(absolutePath, content, "utf-8");
    } catch (error) {
      errors.push(
        `Failed to restore ${relPath}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }

  if (errors.length > 0) {
    throw new Error(`Failed to restore some files:\n${errors.join("\n")}`);
  }
}

export function formatCheckpointList(items: CheckpointListItem[]): string {
  if (items.length === 0) {
    return "No checkpoints. Use /checkpoint create [name].";
  }

  const lines = items.map((item) => {
    const m = item.metadata;
    const when = new Date(m.timestamp).toLocaleString();
    const sizeKb = item.sizeBytes ? `${Math.round(item.sizeBytes / 1024)}KB` : "?";
    return `- ${m.name} (${when}, ${m.messageCount} msgs, ${m.filesChanged.length} files, ${sizeKb})`;
  });

  return `Checkpoints:\n${lines.join("\n")}`;
}
