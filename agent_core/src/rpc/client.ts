// Reverse RPC client - Node child calls Dart parent methods
// Uses the same stdio transport; the Dart side implements these handlers.

import {RpcTransport} from "./transport.js";

export class ReverseRpcClient {
  constructor(private transport: RpcTransport) {}

  async invokeSsh(params: {hostId: string; command: string; timeoutMs?: number; workDir?: string; shell?: string}) {
    return this.request<{exitCode: number; output: string; error?: string; durationMs: number; failureKind?: string}>(
      "rpc:invokeSsh", params,
    );
  }

  async invokeSftp(params: {hostId: string; op: string; remotePath?: string; localPath?: string; targetPath?: string}) {
    return this.request<{success: boolean; output?: string; error?: string}>(
      "rpc:invokeSftp", params,
    );
  }

  async queryKnowledge(params: {query: string; limit?: number; category?: string}) {
    return this.request<{hits: Array<{id: string; title: string; content: string; score: number}>}>(
      "rpc:queryKnowledge", params,
    );
  }

  async saveSession(params: {taskId: string; events: unknown[]; checkpointData?: Record<string, unknown>}) {
    return this.request<{ok: boolean}>(
      "rpc:saveSession", params,
    );
  }

  async callDartTool(params: {toolName: string; args: Record<string, unknown>}) {
    return this.request<{success: boolean; output?: string; error?: string}>(
      "rpc:callDartTool", params,
    );
  }

  private revIdCounter = 0;

  private async request<T>(method: string, params: unknown): Promise<T> {
    // R4: deterministic, monotonically-increasing reverse-RPC request IDs.
    // The old "rev-" + Math.random().toString(36).slice(2) was non-deterministic and could
    // collide under concurrent calls, risking a response being matched to the wrong pending
    // request (R4 stableId/dedup invariant). A per-client counter is stable + unique.
    const id = "rev-" + (++this.revIdCounter).toString(36);
    return this.transport.request<T>({jsonrpc: "2.0", id, method, params});
  }
}
