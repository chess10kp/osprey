// Checkpoint store — conversation + git-tracked file snapshots under .jackal/checkpoints/.
// I/O delegated to lib/jac/workflow/_checkpoints_toolchain.py via bridge.

import { existsSync } from "node:fs";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import {
  bridgeCheckpointsDir,
  bridgeValidateCheckpointName,
  bridgeGetModifiedFiles,
  bridgeCreateCheckpoint,
  bridgeLoadCheckpoint,
  bridgeListCheckpoints,
  bridgeDeleteCheckpoint,
  bridgeRestoreCheckpointFiles,
  bridgeFormatRelativeTime,
  bridgeFormatCheckpointOverlayRow,
  bridgeFormatCheckpointList,
} from "../jac/jac-bridge.js";

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
  return bridgeCheckpointsDir(cwd);
}

export function validateCheckpointName(name: string): { valid: boolean; error?: string } {
  return bridgeValidateCheckpointName(name);
}

export async function getModifiedFiles(cwd: string): Promise<string[]> {
  return bridgeGetModifiedFiles(cwd);
}

export async function createCheckpoint(
  cwd: string,
  input: CreateCheckpointInput,
): Promise<CheckpointMetadata> {
  const raw = await bridgeCreateCheckpoint({
    cwd,
    messages: input.messages as unknown[],
    provider: input.provider,
    model: input.model,
    name: input.name,
    modifiedFiles: input.modifiedFiles,
  });
  return raw as unknown as CheckpointMetadata;
}

export async function loadCheckpoint(cwd: string, name: string): Promise<CheckpointData> {
  const raw = await bridgeLoadCheckpoint(cwd, name);
  return {
    metadata: raw.metadata as unknown as CheckpointMetadata,
    conversation: raw.conversation as unknown as CheckpointConversation,
    fileSnapshots: new Map(Object.entries(raw.fileSnapshots)),
  };
}

export async function listCheckpoints(cwd: string): Promise<CheckpointListItem[]> {
  return await bridgeListCheckpoints(cwd) as unknown as CheckpointListItem[];
}

export async function deleteCheckpoint(cwd: string, name: string): Promise<void> {
  await bridgeDeleteCheckpoint(cwd, name);
}

export async function restoreCheckpointFiles(
  cwd: string,
  snapshots: Map<string, string>,
): Promise<void> {
  await bridgeRestoreCheckpointFiles(cwd, Object.fromEntries(snapshots));
}

export function formatRelativeTime(timestamp: string): string {
  return bridgeFormatRelativeTime(timestamp);
}

export function formatCheckpointOverlayRow(item: CheckpointListItem): string {
  return bridgeFormatCheckpointOverlayRow(item as unknown as Record<string, unknown>);
}

export function formatCheckpointList(items: CheckpointListItem[]): string {
  return bridgeFormatCheckpointList(items as unknown as Array<Record<string, unknown>>);
}
