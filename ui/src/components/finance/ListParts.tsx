import { Spinner } from '@/components/ui/Feedback';

/** The end of a paginated list: a spinner while loading, the count once complete. */
export function ListFooter({ loading, hasMore, count, noun }: { loading: boolean; hasMore: boolean; count: number; noun: [string, string] }) {
  if (loading) {
    return (
      <div style={{ display: 'grid', placeItems: 'center', padding: 'var(--sp-xl) 0' }}>
        <Spinner />
      </div>
    );
  }
  if (hasMore || count === 0) return <div style={{ height: 'var(--sp-lg)' }} />;
  return (
    <p className="t-label-sm t-center" style={{ paddingTop: 'var(--sp-lg)' }}>
      {count} {count === 1 ? noun[0] : noun[1]}
    </p>
  );
}
