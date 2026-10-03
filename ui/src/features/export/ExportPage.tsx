import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { useSearchParams } from 'react-router';

import { Page } from '@/components/layout/Page';
import { CategoryChips } from '@/components/finance/Pickers';
import { Button } from '@/components/ui/Button';
import { Chip, ChipGroup, Segmented } from '@/components/ui/Chip';
import { Badge, ErrorView, Notice, Skeleton } from '@/components/ui/Feedback';
import { DatePickerField, FieldLabel } from '@/components/ui/Fields';
import { Card, CardList, ListRow } from '@/components/ui/Surface';
import { APP_NAME } from '@/domain/defaults';
import {
  datasetHasRows,
  EXPORT_FORMATS,
  exportFileName,
  lastDaysRange,
  monthRangeOf,
  needsAccount,
  REPORT_TYPES,
  requestIsRunnable,
  sameRange,
  supportsCategoryFilter,
  yearRangeOf,
  type ExportDateRange,
  type ExportFormat,
  type ExportReportType,
  type ExportRequest,
} from '@/domain/export/model';
import { renderCsv, renderPrintableHtml } from '@/domain/export/render';
import { accountLabel } from '@/domain/models';
import { useAccounts, useCategories, useCreditCards, usePaymentMethods } from '@/hooks/data';
import { addMonths, isValidIso, today } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { printDocument, shareOrDownload } from '@/lib/share';
import { buildExport } from '@/services/exports';
import { useUserId } from '@/state/auth';
import { useFeedback } from '@/state/feedback';
import { keys } from '@/state/queryClient';
import { useSettings } from '@/state/settings';

import styles from './Export.module.css';

function initialRequest(params: URLSearchParams): ExportRequest {
  const type = REPORT_TYPES.some((r) => r.value === params.get('type')) ? (params.get('type') as ExportReportType) : 'spendingReport';
  const from = params.get('from');
  const to = params.get('to');
  const month = params.get('month');
  let range: ExportDateRange = monthRangeOf(today());
  if (from && to && isValidIso(from) && isValidIso(to)) range = { start: from, endInclusive: to };
  else if (month && isValidIso(month)) range = monthRangeOf(month);
  return { type, range, format: 'pdf', accountId: params.get('account'), categoryIds: [] };
}

/** Statements, expenses, income and summaries as CSV or PDF, built on this device (ExportScreen). */
export function ExportPage() {
  const userId = useUserId();
  const [params] = useSearchParams();
  const { currency } = useSettings();
  const { toast } = useFeedback();
  const accounts = useAccounts().data ?? [];
  const categories = useCategories().data ?? [];
  const methods = usePaymentMethods().data ?? [];
  const cards = (useCreditCards().data ?? []).map((o) => o.card);
  const [request, setRequest] = useState<ExportRequest>(() => initialRequest(params));
  const [exporting, setExporting] = useState(false);
  const accountList = accounts.map((b) => b.account);
  const effective: ExportRequest = {
    ...request,
    accountId: needsAccount(request.type) ? (request.accountId ?? accountList[0]?.id ?? null) : null,
    categoryIds: supportsCategoryFilter(request.type) ? request.categoryIds : [],
  };
  const runnable = requestIsRunnable(effective);

  const preview = useQuery({
    queryKey: keys.exportPreview(userId, { ...effective, format: null }),
    queryFn: () => buildExport({ userId, request: effective, currency, accounts: accountList, categories, paymentMethods: methods, cards }),
    enabled: runnable,
    placeholderData: keepPreviousData,
  });

  const update = (patch: Partial<ExportRequest>) => setRequest((r) => ({ ...r, ...patch }));
  const now = new Date();
  const presets: { label: string; range: ExportDateRange }[] = [
    { label: 'This month', range: monthRangeOf(today(now)) },
    { label: 'Last month', range: monthRangeOf(addMonths(today(now), -1)) },
    { label: 'Last 90 days', range: lastDaysRange(90, now) },
    { label: 'This year', range: yearRangeOf(today(now)) },
  ];

  const run = async () => {
    const data = preview.data;
    if (!data || !datasetHasRows(data.dataset)) return;
    setExporting(true);
    try {
      if (effective.format === 'csv') {
        const bank = accountList.find((a) => a.id === effective.accountId)?.bankName;
        const fileName = exportFileName(effective.type, effective.range, 'csv', needsAccount(effective.type) ? bank : null);
        const outcome = await shareOrDownload(renderCsv(data.dataset), fileName, 'text/csv');
        if (outcome === 'downloaded') toast('success', 'CSV downloaded');
      } else {
        printDocument(renderPrintableHtml(data.dataset, APP_NAME));
        toast('info', 'Choose "Save as PDF" in the print dialog.');
      }
    } catch (error) {
      toast('error', errorMessage(error, 'Could not create the export.'));
    } finally {
      setExporting(false);
    }
  };

  const pickDate = (which: 'start' | 'end', value: string | null) => {
    if (!value) return;
    const { start, endInclusive } = effective.range;
    const range =
      which === 'start'
        ? value > endInclusive
          ? { start: endInclusive, endInclusive: value }
          : { start: value, endInclusive }
        : value < start
          ? { start: value, endInclusive: start }
          : { start, endInclusive: value };
    update({ range });
  };

  const data = preview.data;

  return (
    <Page
      title="Export"
      back="/settings"
      narrow
      bar={
        <Button
          label={`Export ${effective.format.toUpperCase()}`}
          icon={effective.format === 'csv' ? 'csv' : 'print'}
          size="lg"
          block
          busy={exporting}
          busyLabel="Preparing…"
          disabled={!runnable || preview.isFetching || !data || !datasetHasRows(data.dataset)}
          onClick={() => void run()}
        />
      }
    >
      <div>
        <FieldLabel text="Report" />
        <CardList indent={12}>
          {REPORT_TYPES.map((type) => (
            <ListRow
              key={type.value}
              dense
              title={type.label}
              subtitle={type.description}
              trailing={type.value === effective.type ? <Badge label="Selected" icon="check" tone="var(--primary)" /> : undefined}
              onClick={() => update({ type: type.value })}
            />
          ))}
        </CardList>
      </div>

      {needsAccount(effective.type) ? (
        <div>
          <FieldLabel text="Account" />
          {accountList.length ? (
            <ChipGroup label="Account">
              {accountList.map((account) => (
                <Chip key={account.id} label={accountLabel(account)} icon="bank" selected={effective.accountId === account.id} onClick={() => update({ accountId: account.id })} />
              ))}
            </ChipGroup>
          ) : (
            <Notice message="Add a bank account before exporting a statement." />
          )}
        </div>
      ) : null}

      <div className="stack gap-sm">
        <FieldLabel text="Period" />
        <ChipGroup label="Period presets">
          {presets.map((preset) => (
            <Chip key={preset.label} label={preset.label} selected={sameRange(effective.range, preset.range)} onClick={() => update({ range: preset.range })} />
          ))}
        </ChipGroup>
        <div className={styles.range}>
          <DatePickerField label="Start date" value={effective.range.start} onChange={(v) => pickDate('start', v)} min="2010-01-01" />
          <span className="t-body-sm">to</span>
          <DatePickerField label="End date" value={effective.range.endInclusive} onChange={(v) => pickDate('end', v)} icon="calendarRange" min="2010-01-01" />
        </div>
      </div>

      {supportsCategoryFilter(effective.type) ? (
        <div className="stack gap-sm">
          <FieldLabel text="Categories" hint={effective.categoryIds.length ? `${effective.categoryIds.length} selected` : null} />
          <ChipGroup label="All categories">
            <Chip label="All categories" selected={!effective.categoryIds.length} onClick={() => update({ categoryIds: [] })} />
          </ChipGroup>
          <CategoryChips
            categories={categories}
            isSelected={(id) => effective.categoryIds.includes(id)}
            onToggle={(id) =>
              update({
                categoryIds: effective.categoryIds.includes(id) ? effective.categoryIds.filter((c) => c !== id) : [...effective.categoryIds, id],
              })
            }
          />
        </div>
      ) : null}

      <div>
        <FieldLabel text="Format" />
        <Segmented<ExportFormat>
          label="Format"
          value={effective.format}
          options={EXPORT_FORMATS.map((f) => ({ value: f.value, label: f.label, icon: f.value === 'csv' ? 'table' : 'document' }))}
          onChange={(format) => update({ format })}
        />
        <p className="t-label-sm" style={{ padding: '6px 4px 0' }}>
          {EXPORT_FORMATS.find((f) => f.value === effective.format)?.description}
          {effective.format === 'pdf' ? ' — saved with the print dialog’s “Save as PDF”.' : '.'}
        </p>
      </div>

      <div>
        <FieldLabel text="Preview" />
        {!runnable ? (
          <Notice message="Choose an account to preview the statement." />
        ) : preview.isPending ? (
          <Card>
            <div className="stack gap-sm">
              <Skeleton width={140} height={16} />
              <Skeleton height={30} />
              <Skeleton height={30} />
            </div>
          </Card>
        ) : preview.isError || !data ? (
          <ErrorView compact message={errorMessage(preview.error, 'Could not load the data.')} onRetry={() => void preview.refetch()} />
        ) : !datasetHasRows(data.dataset) ? (
          <Notice icon="inbox" message="Nothing to export for this period. Try a wider date range or a different report." />
        ) : (
          <Card>
            <div className="stack gap-sm" style={{ opacity: preview.isPlaceholderData ? 0.6 : 1 }}>
              <div className="row gap-sm">
                <span className="grow t-title-sm">{data.dataset.title}</span>
                <Badge label={data.dataset.periodLabel} />
              </div>
              {data.dataset.subtitle ? <span className="t-body-sm">{data.dataset.subtitle}</span> : null}
              <div className={styles.summary}>
                {data.dataset.summary.map((item) => (
                  <div key={item.label} className="row gap-sm">
                    <span className="grow t-body-sm">{item.label}</span>
                    <span className={item.emphasis ? 't-title-md money' : 't-body-md money'}>{item.value}</span>
                  </div>
                ))}
              </div>
              <span className="t-label-sm">
                {data.dataset.sections
                  .filter((s) => s.rows.length)
                  .map((s) => `${s.title}: ${s.rows.length} ${s.rows.length === 1 ? 'row' : 'rows'}`)
                  .join(' · ')}
              </span>
            </div>
          </Card>
        )}
        {data?.truncated ? (
          <div style={{ marginTop: 'var(--sp-sm)' }}>
            <Notice
              icon="warning"
              tone="var(--warning)"
              message="This period has more rows than one export can hold. Narrow the date range to include everything."
            />
          </div>
        ) : null}
      </div>

      <Notice icon="download" message="Exports are generated on this device. Nothing is uploaded." />
    </Page>
  );
}
