/**
 * Hands a generated file to the user, the web way: the native share sheet
 * where the platform offers file sharing (iOS, Android), otherwise a
 * download. Nothing is uploaded anywhere.
 */
export async function shareOrDownload(content: string, fileName: string, mimeType: string): Promise<'shared' | 'downloaded' | 'cancelled'> {
  const blob = new Blob([content], { type: `${mimeType};charset=utf-8` });
  const file = new File([blob], fileName, { type: mimeType });
  const coarse = window.matchMedia('(pointer: coarse)').matches;
  if (coarse && typeof navigator.canShare === 'function' && navigator.canShare({ files: [file] })) {
    try {
      await navigator.share({ files: [file], title: fileName });
      return 'shared';
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return 'cancelled';
      // Fall through to a plain download.
    }
  }
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = fileName;
  link.rel = 'noopener';
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30_000);
  return 'downloaded';
}

/**
 * Prints a self-contained HTML document through the browser's print dialog,
 * where "Save as PDF" produces the file. The document holds no script.
 */
export function printDocument(html: string): void {
  const frame = document.createElement('iframe');
  frame.setAttribute('aria-hidden', 'true');
  frame.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden';
  frame.srcdoc = html;
  frame.onload = () => {
    const view = frame.contentWindow;
    if (!view) return;
    const cleanup = () => setTimeout(() => frame.remove(), 1000);
    view.addEventListener('afterprint', cleanup, { once: true });
    view.focus();
    view.print();
    // Some browsers never fire afterprint for an iframe.
    setTimeout(() => frame.remove(), 120_000);
  };
  document.body.append(frame);
}
