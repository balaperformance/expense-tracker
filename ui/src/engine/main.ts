/**
 * Entry point of the phone app's statement engine bundle (see
 * statementEngine.ts). Wires the engine to the Android host:
 *
 *   host → engine   window.__engineCall(id, name, argsJson)
 *   engine → host   EngineBridge.result(id, resultJson)
 *                   EngineBridge.fileSize(token) / EngineBridge.readChunk(token, index)
 *
 * PDF.js runs on this thread (its "fake worker"): the page is loaded from an
 * in-memory document, where a separate worker script cannot be fetched, and
 * a hidden WebView has no UI to keep responsive anyway.
 */
import * as pdfWorker from 'pdfjs-dist/build/pdf.worker.mjs';

import { createEngine, EngineFailure, type StatementEngine } from './statementEngine';

type HostBridge = {
  result: (id: string, json: string) => void;
  fileSize: (token: string) => number;
  readChunk: (token: string, index: number) => string;
};

declare global {
  var pdfjsWorker: unknown;
  var EngineBridge: HostBridge | undefined;
  var __engineCall: ((id: string, name: string, argsJson: string) => void) | undefined;
}

globalThis.pdfjsWorker = pdfWorker;

/** The host's chunk size; it decides, the engine only asks for chunks until the bytes are complete. */
function readFromHost(token: string): Promise<Uint8Array> {
  const host = globalThis.EngineBridge;
  if (!host) return Promise.reject(new EngineFailure({ code: 'failed', message: 'The statement reader is not connected.' }));
  const size = host.fileSize(token);
  if (size < 0) return Promise.reject(new EngineFailure({ code: 'failed', message: 'That file is no longer available. Choose it again.' }));
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (let index = 0; offset < size; index += 1) {
    const binary = atob(host.readChunk(token, index));
    if (!binary.length) break;
    for (let i = 0; i < binary.length; i += 1) bytes[offset + i] = binary.charCodeAt(i);
    offset += binary.length;
  }
  return Promise.resolve(offset === size ? bytes : bytes.slice(0, offset));
}

const engine: StatementEngine = createEngine(readFromHost);

globalThis.__engineCall = (id, name, argsJson) => {
  const reply = (payload: unknown) => globalThis.EngineBridge?.result(id, JSON.stringify(payload));
  const fn = (engine as Record<string, ((args: unknown) => unknown) | undefined>)[name];
  if (!fn) {
    reply({ ok: false, error: { code: 'failed', message: `Unknown engine call: ${name}` } });
    return;
  }
  Promise.resolve()
    .then(() => fn(JSON.parse(argsJson) as unknown))
    .then(
      (value) => reply({ ok: true, value: value ?? null }),
      (error: unknown) =>
        reply({
          ok: false,
          error: error instanceof EngineFailure ? error.failure : { code: 'failed', message: error instanceof Error ? error.message : 'Unexpected error' },
        }),
    );
};
