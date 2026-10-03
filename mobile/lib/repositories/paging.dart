import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

/// One page of rows, plus the total when it was asked for.
typedef PageFetch = Future<(List<Map<String, dynamic>>, int?)> Function(
  int from,
  int to,
  bool withCount,
);

const int _pageRows = 1000;

/// Every row of a query, read page by page.
///
/// PostgREST caps one response at the project's max-rows (1000 by default),
/// so a figure summed over a long history — a bank balance, a card's
/// outstanding — would otherwise be silently wrong once the history passes
/// the cap. The first page asks for the exact count and reading continues
/// until that many rows have arrived, whatever page size the server
/// actually allows. [max] stops early for reads that cap their size on
/// purpose (exports). The query behind [page] must use a stable order.
Future<List<Map<String, dynamic>>> fetchAllPages(
  PageFetch page, {
  int? max,
}) async {
  final int cap = max ?? 1 << 30;
  final (List<Map<String, dynamic>> first, int? count) =
      await page(0, math.min(_pageRows, cap) - 1, true);
  final List<Map<String, dynamic>> rows = List<Map<String, dynamic>>.of(first);
  // Without a count, keep reading until a page comes back empty.
  final int total = math.min(count ?? (1 << 30), cap);
  while (rows.length < total) {
    final int size = math.min(_pageRows, total - rows.length);
    final (List<Map<String, dynamic>> next, int? _) =
        await page(rows.length, rows.length + size - 1, false);
    if (next.isEmpty) break;
    rows.addAll(next);
  }
  return rows.length > cap ? rows.sublist(0, cap) : rows;
}

/// Adapts a PostgREST query to [PageFetch]. [build] must return a fresh,
/// fully filtered and ordered query each time it is called.
PageFetch postgrestPages(
  PostgrestTransformBuilder<List<Map<String, dynamic>>> Function() build,
) {
  return (int from, int to, bool withCount) async {
    final PostgrestTransformBuilder<List<Map<String, dynamic>>> query =
        build().range(from, to);
    if (withCount) {
      final PostgrestResponse<List<Map<String, dynamic>>> response =
          await query.count(CountOption.exact);
      return (response.data, response.count);
    }
    return (await query, null);
  };
}

/// Signed sum of ledger rows in whole cents, so thousands of rows cannot drift.
double netOfRows(Iterable<Map<String, dynamic>> rows) {
  int cents = 0;
  for (final Map<String, dynamic> row in rows) {
    final int amount = (((row['amount'] as num?)?.toDouble() ?? 0) * 100).round();
    cents += row['direction'] == 'credit' ? amount : -amount;
  }
  return cents / 100;
}

/// `yyyy-MM` → total, summed in whole cents.
Map<String, double> monthlyTotals(
  Iterable<Map<String, dynamic>> rows,
  String dateKey,
) {
  final Map<String, int> cents = <String, int>{};
  for (final Map<String, dynamic> row in rows) {
    final String bucket = (row[dateKey] as String).substring(0, 7);
    cents[bucket] = (cents[bucket] ?? 0) +
        (((row['amount'] as num?)?.toDouble() ?? 0) * 100).round();
  }
  return cents.map((String key, int value) => MapEntry(key, value / 100));
}
