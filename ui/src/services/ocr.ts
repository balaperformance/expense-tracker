/**
 * On-device receipt OCR — the web counterpart of the ML Kit scanner.
 *
 * The photo is decoded, tidied and read entirely in this browser tab by a
 * self-hosted Tesseract worker. No image, pixel or recognised text leaves the
 * device, and no third-party script is loaded. The engine (~3 MB of model
 * plus a WASM core) is fetched on first use only, then cached by the service
 * worker for offline scans.
 */
import type { Worker as TesseractWorker } from 'tesseract.js';

import { parseReceiptLines } from '@/domain/receipt/parser';
import type { ReceiptResult, ReceiptScanProblem } from '@/domain/receipt/result';

export type ScanOutcome = { ok: true; result: ReceiptResult } | { ok: false; problem: ReceiptScanProblem };

const ASSETS = '/tesseract';
/** Longest edge fed to the recogniser: plenty for receipt text, far faster than 12 MP. */
const MAX_EDGE = 2000;
/** Frees the engine's memory once scanning is done for a while. */
const IDLE_MS = 90_000;

let workerPromise: Promise<TesseractWorker> | null = null;
let idleTimer: ReturnType<typeof setTimeout> | undefined;

async function getWorker(): Promise<TesseractWorker> {
  if (!workerPromise) {
    workerPromise = (async () => {
      // A CommonJS package: depending on interop the API is the module itself
      // or its default export.
      const mod = await import('tesseract.js');
      const { createWorker, OEM, PSM } =
        'createWorker' in mod ? mod : (mod as unknown as { default: typeof mod }).default;
      const worker = await createWorker('eng', OEM.LSTM_ONLY, {
        workerPath: `${ASSETS}/worker.min.js`,
        corePath: ASSETS,
        langPath: ASSETS,
        workerBlobURL: false,
        gzip: true,
      });
      // A receipt is one column of lines of varying size.
      await worker.setParameters({ tessedit_pageseg_mode: PSM.SINGLE_COLUMN, preserve_interword_spaces: '1' });
      return worker;
    })().catch((error: unknown) => {
      workerPromise = null;
      throw error;
    });
  }
  return workerPromise;
}

function scheduleRelease(): void {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => {
    const pending = workerPromise;
    workerPromise = null;
    void pending?.then((worker) => worker.terminate()).catch(() => undefined);
  }, IDLE_MS);
}

/** Downscales and greys the photo, with a gentle contrast lift for thermal paper. */
async function prepare(file: Blob): Promise<HTMLCanvasElement> {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, MAX_EDGE / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(bitmap.width * scale));
  canvas.height = Math.max(1, Math.round(bitmap.height * scale));
  const context = canvas.getContext('2d', { willReadFrequently: true });
  if (!context) throw new Error('Canvas unavailable');
  context.filter = 'grayscale(1) contrast(1.25)';
  context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  return canvas;
}

/** Starts downloading the engine early, e.g. when the scan sheet opens. */
export function warmUpOcr(): void {
  void getWorker().catch(() => undefined);
}

export async function scanReceipt(file: Blob): Promise<ScanOutcome> {
  let canvas: HTMLCanvasElement;
  try {
    canvas = await prepare(file);
  } catch {
    return { ok: false, problem: 'unreadable' };
  }

  try {
    const worker = await getWorker();
    const { data } = await worker.recognize(canvas);
    const lines = data.text.split(/\r?\n/);
    const result = parseReceiptLines(lines);
    if (!result.rawLines.length) return { ok: false, problem: 'unreadable' };
    return { ok: true, result };
  } catch (error) {
    console.warn('Receipt OCR failed', error instanceof Error ? error.name : 'unknown');
    return { ok: false, problem: 'engineFailure' };
  } finally {
    canvas.width = 0;
    canvas.height = 0;
    scheduleRelease();
  }
}
