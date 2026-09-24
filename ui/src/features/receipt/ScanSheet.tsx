import { useRef, useState } from 'react';

import { Dialog, Sheet } from '@/components/ui/Sheet';
import { Notice, Spinner } from '@/components/ui/Feedback';
import { CardList, IconWell, ListRow } from '@/components/ui/Surface';
import { RECEIPT_PROBLEM_MESSAGE, type ReceiptResult } from '@/domain/receipt/result';
import { scanReceipt, warmUpOcr } from '@/services/ocr';
import { useFeedback } from '@/state/feedback';

/**
 * Pick a receipt photo — camera or library — and read it on this device
 * (startReceiptScan). The photo is never uploaded or kept.
 */
export function ScanSheet({ open, onClose, onScanned }: { open: boolean; onClose: () => void; onScanned: (result: ReceiptResult) => void }) {
  const { toast } = useFeedback();
  const camera = useRef<HTMLInputElement>(null);
  const library = useRef<HTMLInputElement>(null);
  const [reading, setReading] = useState(false);

  const onFile = async (file: File | undefined) => {
    if (!file) return;
    onClose();
    setReading(true);
    const outcome = await scanReceipt(file);
    setReading(false);
    if (outcome.ok) onScanned(outcome.result);
    else if (outcome.problem !== 'cancelled') toast('error', RECEIPT_PROBLEM_MESSAGE[outcome.problem]);
  };

  const pick = (input: HTMLInputElement | null) => {
    warmUpOcr();
    if (!input) return;
    input.value = '';
    input.click();
  };

  return (
    <>
      <input
        ref={camera}
        type="file"
        accept="image/*"
        capture="environment"
        hidden
        onChange={(e) => void onFile(e.target.files?.[0])}
      />
      <input ref={library} type="file" accept="image/*" hidden onChange={(e) => void onFile(e.target.files?.[0])} />
      <Sheet open={open} onClose={onClose} title="Scan receipt" subtitle="Read the amount, merchant and date from a photo">
        <CardList>
          <ListRow
            leading={<IconWell icon="camera" />}
            title="Take photo"
            subtitle="Point the camera at the receipt"
            chevron
            onClick={() => pick(camera.current)}
          />
          <ListRow
            leading={<IconWell icon="gallery" />}
            title="Choose from library"
            subtitle="Pick a photo you already have"
            chevron
            onClick={() => pick(library.current)}
          />
        </CardList>
        <Notice icon="lock" message="The receipt is read on this device and the photo is not saved or uploaded anywhere." />
      </Sheet>
      <Dialog open={reading} onClose={() => undefined} title="Reading the receipt" actions={null}>
        <div className="row gap-md">
          <Spinner size={26} />
          <span>This happens on your device. The first scan also downloads the text reader.</span>
        </div>
      </Dialog>
    </>
  );
}
