import '../core/utils/date_utils.dart';

/// The Reports insights, as the shared engine returns them (see
/// ui/src/engine/insightsEngine.ts). Every figure, sentence and estimate is
/// computed there by the web app's own code; these are plain read-only views
/// of its JSON, so the phone shows exactly what the web shows.

double _num(Object? value) => value is num ? value.toDouble() : 0;
double? _numOrNull(Object? value) => value is num ? value.toDouble() : null;
int _int(Object? value) => value is num ? value.toInt() : 0;
String _str(Object? value) => value is String ? value : '';
String? _strOrNull(Object? value) => value is String ? value : null;
bool _bool(Object? value) => value == true;
DateTime _date(Object? value) => AppDateUtils.parseDate(_str(value));

List<Map<String, Object?>> _maps(Object? value) => value is List
    ? value.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> m) => m.cast<String, Object?>()).toList()
    : const <Map<String, Object?>>[];

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const <String>[];

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const <String, Object?>{};

/// A date range with its labels ("1 Aug – 5 Oct 2026", "Aug–Oct").
class InsightPeriod {
  const InsightPeriod({required this.start, required this.end, required this.label, required this.short});

  factory InsightPeriod.fromJson(Object? json) {
    final Map<String, Object?> m = _map(json);
    return InsightPeriod(start: _date(m['start']), end: _date(m['end']), label: _str(m['label']), short: _str(m['short']));
  }

  final DateTime start;
  final DateTime end;
  final String label;
  final String short;
}

/// One expense in a drill-down or a list, names already resolved.
class InsightRow {
  const InsightRow({
    required this.id,
    required this.amount,
    required this.date,
    required this.title,
    required this.categoryName,
    this.categoryColor,
    this.categoryIcon,
    this.funding,
    this.refunded = 0,
  });

  factory InsightRow.fromJson(Map<String, Object?> m) {
    final Map<String, Object?> category = _map(m['category']);
    return InsightRow(
      id: _str(m['id']),
      amount: _num(m['amount']),
      date: _date(m['date']),
      title: _str(m['title']),
      categoryName: _str(category['name']),
      categoryColor: _strOrNull(category['color']),
      categoryIcon: _strOrNull(category['icon']),
      funding: _strOrNull(m['funding']),
      refunded: _num(m['refunded']),
    );
  }

  final String id;
  final double amount;
  final DateTime date;
  final String title;
  final String categoryName;
  final String? categoryColor;
  final String? categoryIcon;

  /// The card, account or payment method it was paid with.
  final String? funding;

  /// What a card refund linked to it has given back.
  final double refunded;
}

/// Where a figure leads: the transactions behind it, a recurring payment, or
/// an analysis section.
class InsightDrill {
  const InsightDrill.rows({required this.title, this.subtitle, required this.ids})
      : type = 'rows',
        key = null,
        section = null;

  const InsightDrill._(this.type, {this.key, this.section})
      : title = '',
        subtitle = null,
        ids = const <String>[];

  static InsightDrill? fromJson(Object? json) {
    if (json is! Map) return null;
    final Map<String, Object?> m = json.cast<String, Object?>();
    return switch (m['type']) {
      'rows' => InsightDrill.rows(title: _str(m['title']), subtitle: _strOrNull(m['subtitle']), ids: _strings(m['ids'])),
      'recurring' => InsightDrill._('recurring', key: _str(m['key'])),
      'section' => InsightDrill._('section', section: _str(m['section'])),
      _ => null,
    };
  }

  /// 'rows', 'recurring' or 'section'.
  final String type;
  final String title;
  final String? subtitle;
  final List<String> ids;

  /// The recurring payment, for 'recurring'.
  final String? key;

  /// The analytics section ('changes', 'recurring', 'savings', …), for 'section'.
  final String? section;
}

/// A saving estimate — always marked as one.
class InsightSaving {
  const InsightSaving({required this.monthly, required this.yearly});

  static InsightSaving? fromJson(Object? json) {
    if (json is! Map) return null;
    return InsightSaving(monthly: _num(json['monthly']), yearly: _num(json['yearly']));
  }

  final double monthly;
  final double yearly;
}

class InsightHighlight {
  const InsightHighlight({
    required this.id,
    required this.tone,
    required this.topic,
    required this.title,
    required this.why,
    this.action,
    this.saving,
    this.drill,
  });

  factory InsightHighlight.fromJson(Map<String, Object?> m) => InsightHighlight(
        id: _str(m['id']),
        tone: _str(m['tone']),
        topic: _str(m['topic']),
        title: _str(m['title']),
        why: _str(m['why']),
        action: _strOrNull(m['action']),
        saving: InsightSaving.fromJson(m['saving']),
        drill: InsightDrill.fromJson(m['drill']),
      );

  final String id;

  /// 'alert', 'warning', 'caution', 'positive' or 'info'.
  final String tone;

  /// 'increase', 'decrease', 'recurring', 'price', 'habit', 'charges',
  /// 'unusual', 'card', 'income' or 'upcoming'.
  final String topic;
  final String title;
  final String why;
  final String? action;
  final InsightSaving? saving;
  final InsightDrill? drill;
}

/// A subscription, bill, EMI or renewal found in the history.
class RecurringItem {
  const RecurringItem({
    required this.key,
    required this.label,
    required this.kind,
    required this.kindLabel,
    required this.cadence,
    required this.cadenceLabel,
    required this.unitOne,
    required this.unitMany,
    required this.streak,
    required this.amount,
    required this.variable,
    required this.monthlyCost,
    required this.yearlyCost,
    required this.totalPaid,
    required this.lastDate,
    required this.nextDate,
    required this.active,
    required this.trend,
    required this.priceChange,
    required this.explanation,
    required this.extraCount,
    required this.payments,
  });

  factory RecurringItem.fromJson(Map<String, Object?> m) {
    final List<String> unit = _strings(m['unit']);
    final Map<String, Object?> price = _map(m['priceChange']);
    return RecurringItem(
      key: _str(m['key']),
      label: _str(m['label']),
      kind: _str(m['kind']),
      kindLabel: _str(m['kindLabel']),
      cadence: _str(m['cadence']),
      cadenceLabel: _str(m['cadenceLabel']),
      unitOne: unit.isNotEmpty ? unit.first : '',
      unitMany: unit.length > 1 ? unit[1] : '',
      streak: _int(m['streak']),
      amount: _num(m['amount']),
      variable: _bool(m['variable']),
      monthlyCost: _num(m['monthlyCost']),
      yearlyCost: _num(m['yearlyCost']),
      totalPaid: _num(m['totalPaid']),
      lastDate: _date(m['lastDate']),
      nextDate: _date(m['nextDate']),
      active: _bool(m['active']),
      trend: _str(m['trend']),
      priceChange: price.isEmpty
          ? null
          : (from: _num(price['from']), to: _num(price['to']), since: _date(price['since'])),
      explanation: _str(m['explanation']),
      extraCount: _int(m['extraCount']),
      payments: _maps(m['payments']).map(InsightRow.fromJson).toList(),
    );
  }

  final String key;
  final String label;

  /// 'subscription', 'insurance', 'fitness', 'loan', 'utility', 'rent',
  /// 'education' or 'other'.
  final String kind;
  final String kindLabel;
  final String cadence;
  final String cadenceLabel;

  /// "month" / "months" — what one payment of the rhythm is.
  final String unitOne;
  final String unitMany;
  final int streak;
  final double amount;
  final bool variable;
  final double monthlyCost;
  final double yearlyCost;
  final double totalPaid;
  final DateTime lastDate;
  final DateTime nextDate;
  final bool active;

  /// 'up', 'down' or 'flat'.
  final String trend;
  final ({double from, double to, DateTime since})? priceChange;
  final String explanation;

  /// Charges in the same cycle as a regular one: possible double charges.
  final int extraCount;

  /// Every payment behind it, newest first.
  final List<InsightRow> payments;
}

class SavingIdea {
  const SavingIdea({
    required this.id,
    required this.title,
    required this.evidence,
    required this.suggestion,
    required this.saving,
    required this.drill,
  });

  factory SavingIdea.fromJson(Map<String, Object?> m) => SavingIdea(
        id: _str(m['id']),
        title: _str(m['title']),
        evidence: _strings(m['evidence']),
        suggestion: _str(m['suggestion']),
        saving: InsightSaving.fromJson(m['saving']) ?? const InsightSaving(monthly: 0, yearly: 0),
        drill: InsightDrill.fromJson(m['drill']),
      );

  final String id;
  final String title;
  final List<String> evidence;
  final String suggestion;
  final InsightSaving saving;
  final InsightDrill? drill;
}

class UnusualItem {
  const UnusualItem({required this.type, required this.explanation, required this.ids});

  factory UnusualItem.fromJson(Map<String, Object?> m) =>
      UnusualItem(type: _str(m['type']), explanation: _str(m['explanation']), ids: _strings(m['ids']));

  /// 'large' or 'duplicate'.
  final String type;
  final String explanation;
  final List<String> ids;

  bool get isLarge => type == 'large';
}

/// A category that moved the comparison, and why.
class ChangeMover {
  const ChangeMover({
    required this.key,
    required this.label,
    required this.delta,
    required this.currentCount,
    required this.reason,
    required this.ids,
  });

  factory ChangeMover.fromJson(Map<String, Object?> m) => ChangeMover(
        key: _str(m['key']),
        label: _str(m['label']),
        delta: _num(m['delta']),
        currentCount: _int(m['currentCount']),
        reason: _str(m['reason']),
        ids: _strings(m['ids']),
      );

  final String key;
  final String label;
  final double delta;
  final int currentCount;
  final String reason;
  final List<String> ids;
}

/// What changed: this period against the one before.
class ChangesView {
  const ChangesView({
    required this.current,
    required this.previous,
    required this.compared,
    required this.headline,
    required this.reasons,
    required this.currentCount,
    required this.ids,
    required this.movers,
  });

  factory ChangesView.fromJson(Object? json) {
    final Map<String, Object?> m = _map(json);
    return ChangesView(
      current: InsightPeriod.fromJson(m['current']),
      previous: InsightPeriod.fromJson(m['previous']),
      compared: _bool(m['compared']),
      headline: _str(m['headline']),
      reasons: _strings(m['reasons']),
      currentCount: _int(m['currentCount']),
      ids: _strings(m['ids']),
      movers: _maps(m['movers']).map(ChangeMover.fromJson).toList(),
    );
  }

  final InsightPeriod current;
  final InsightPeriod previous;

  /// The period before is inside the recorded history, so the two compare.
  final bool compared;
  final String headline;
  final List<String> reasons;
  final int currentCount;
  final List<String> ids;
  final List<ChangeMover> movers;
}

/// Highlights and the analysis that does not depend on a chosen range.
class InsightsOverview {
  const InsightsOverview({
    required this.session,
    required this.today,
    required this.since,
    required this.historyStart,
    required this.enoughData,
    required this.highlights,
    required this.recurring,
    required this.recurringMonthly,
    required this.runningCount,
    required this.savings,
    required this.unusual,
    required this.changes,
    required this.presets,
    required this.showCards,
  });

  factory InsightsOverview.fromJson(Map<String, Object?> m) => InsightsOverview(
        session: _str(m['session']),
        today: _date(m['today']),
        since: _date(m['since']),
        historyStart: _date(m['historyStart']),
        enoughData: _bool(m['enoughData']),
        highlights: _maps(m['highlights']).map(InsightHighlight.fromJson).toList(),
        recurring: _maps(m['recurring']).map(RecurringItem.fromJson).toList(),
        recurringMonthly: _num(m['recurringMonthly']),
        runningCount: _int(m['runningCount']),
        savings: _maps(m['savings']).map(SavingIdea.fromJson).toList(),
        unusual: _maps(m['unusual']).map(UnusualItem.fromJson).toList(),
        changes: ChangesView.fromJson(m['changes']),
        presets: _maps(m['presets'])
            .map((Map<String, Object?> p) => (value: _str(p['value']), label: _str(p['label'])))
            .toList(),
        showCards: _bool(m['showCards']),
      );

  final String session;
  final DateTime today;
  final DateTime since;
  final DateTime historyStart;
  final bool enoughData;
  final List<InsightHighlight> highlights;
  final List<RecurringItem> recurring;
  final double recurringMonthly;
  final int runningCount;
  final List<SavingIdea> savings;
  final List<UnusualItem> unusual;
  final ChangesView changes;

  /// The date-range presets, in order ("This month" … "Last 12 months").
  final List<({String value, String label})> presets;

  /// Cards are used, or charged fees: the Cards section has something to say.
  final bool showCards;

  List<RecurringItem> get running => recurring.where((RecurringItem r) => r.active).toList();

  RecurringItem? recurringByKey(String key) {
    for (final RecurringItem item in recurring) {
      if (item.key == key) return item;
    }
    return null;
  }
}

/// What narrows the Spending view. Empty lists mean "any".
class SpendingFilter {
  const SpendingFilter({
    this.tagIds = const <String>[],
    this.categoryIds = const <String>[],
    this.merchantKeys = const <String>[],
    this.paymentMethodIds = const <String>[],
    this.sources = const <String>[],
  });

  static const SpendingFilter empty = SpendingFilter();

  final List<String> tagIds;
  final List<String> categoryIds;
  final List<String> merchantKeys;
  final List<String> paymentMethodIds;

  /// `account:<id>`, `card:<id>` or `cash`.
  final List<String> sources;

  /// Filters other than tags, for the Filters chip's count.
  int get extraCount => categoryIds.length + merchantKeys.length + paymentMethodIds.length + sources.length;

  int get count => tagIds.length + extraCount;

  bool get isEmpty => count == 0;

  SpendingFilter copyWith({
    List<String>? tagIds,
    List<String>? categoryIds,
    List<String>? merchantKeys,
    List<String>? paymentMethodIds,
    List<String>? sources,
  }) =>
      SpendingFilter(
        tagIds: tagIds ?? this.tagIds,
        categoryIds: categoryIds ?? this.categoryIds,
        merchantKeys: merchantKeys ?? this.merchantKeys,
        paymentMethodIds: paymentMethodIds ?? this.paymentMethodIds,
        sources: sources ?? this.sources,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'tagIds': tagIds,
        'categoryIds': categoryIds,
        'merchantKeys': merchantKeys,
        'paymentMethodIds': paymentMethodIds,
        'sources': sources,
      };
}

/// One group of the "Where it went" breakdown.
class SpendGroup {
  const SpendGroup({
    required this.key,
    required this.label,
    required this.total,
    required this.count,
    required this.share,
    required this.ids,
    this.color,
  });

  factory SpendGroup.fromJson(Map<String, Object?> m) => SpendGroup(
        key: _str(m['key']),
        label: _str(m['label']),
        total: _num(m['total']),
        count: _int(m['count']),
        share: _num(m['share']),
        ids: _strings(m['ids']),
        color: _strOrNull(m['color']),
      );

  final String key;
  final String label;
  final double total;
  final int count;

  /// Of the slice's total. Tags overlap, so tag shares may add past 100%.
  final double share;
  final List<String> ids;

  /// The category's colour, for category groups.
  final String? color;
}

/// One bar of "Spending over time": a week or a month.
class SpendBucket {
  const SpendBucket({
    required this.start,
    required this.end,
    required this.label,
    required this.total,
    required this.count,
    required this.ids,
  });

  factory SpendBucket.fromJson(Map<String, Object?> m) => SpendBucket(
        start: _date(m['start']),
        end: _date(m['end']),
        label: _str(m['label']),
        total: _num(m['total']),
        count: _int(m['count']),
        ids: _strings(m['ids']),
      );

  final DateTime start;
  final DateTime end;
  final String label;
  final double total;
  final int count;
  final List<String> ids;
}

/// What the filter sheet can offer for the chosen range.
class SpendingFilterOptions {
  const SpendingFilterOptions({
    required this.tags,
    required this.categories,
    required this.merchants,
    required this.sources,
    required this.paymentMethods,
  });

  factory SpendingFilterOptions.fromJson(Object? json) {
    final Map<String, Object?> m = _map(json);
    return SpendingFilterOptions(
      tags: _maps(m['tags']).map((Map<String, Object?> t) => (id: _str(t['id']), name: _str(t['name']), count: _int(t['count']))).toList(),
      categories: _maps(m['categories']).map((Map<String, Object?> c) => (id: _str(c['id']), name: _str(c['name']))).toList(),
      merchants: _maps(m['merchants']).map((Map<String, Object?> c) => (key: _str(c['key']), label: _str(c['label']), total: _num(c['total']))).toList(),
      sources: _maps(m['sources']).map((Map<String, Object?> c) => (key: _str(c['key']), label: _str(c['label']))).toList(),
      paymentMethods: _maps(m['paymentMethods']).map((Map<String, Object?> c) => (id: _str(c['id']), name: _str(c['name']))).toList(),
    );
  }

  final List<({String id, String name, int count})> tags;
  final List<({String id, String name})> categories;

  /// Most spent first.
  final List<({String key, String label, double total})> merchants;
  final List<({String key, String label})> sources;
  final List<({String id, String name})> paymentMethods;
}

/// A slice of spending: summary, trend, breakdowns and the largest expenses.
class SpendingView {
  const SpendingView({
    required this.period,
    required this.previous,
    required this.total,
    required this.count,
    required this.average,
    required this.previousTotal,
    required this.change,
    required this.shareOfAll,
    required this.previousIncomplete,
    required this.byWeek,
    required this.trend,
    required this.monthOverMonth,
    required this.summary,
    required this.ids,
    required this.multiTagged,
    required this.groups,
    required this.largest,
    required this.options,
    required this.earliestCustomStart,
  });

  factory SpendingView.fromJson(Map<String, Object?> m) {
    final Map<String, Object?> mom = _map(m['monthOverMonth']);
    final Map<String, Object?> groups = _map(m['groups']);
    return SpendingView(
      period: InsightPeriod.fromJson(m['period']),
      previous: InsightPeriod.fromJson(m['previous']),
      total: _num(m['total']),
      count: _int(m['count']),
      average: _num(m['average']),
      previousTotal: _num(m['previousTotal']),
      change: _numOrNull(m['change']),
      shareOfAll: _num(m['shareOfAll']),
      previousIncomplete: _bool(m['previousIncomplete']),
      byWeek: m['granularity'] == 'week',
      trend: _maps(m['trend']).map(SpendBucket.fromJson).toList(),
      monthOverMonth: mom.isEmpty
          ? null
          : (
              current: _str(mom['current']),
              previous: _str(mom['previous']),
              currentTotal: _num(mom['currentTotal']),
              previousTotal: _num(mom['previousTotal']),
              change: _numOrNull(mom['change']),
            ),
      summary: _strings(m['summary']),
      ids: _strings(m['ids']),
      multiTagged: _bool(m['multiTagged']),
      groups: <String, List<SpendGroup>>{
        for (final String by in const <String>['tag', 'category', 'merchant', 'source'])
          by: _maps(groups[by]).map(SpendGroup.fromJson).toList(),
      },
      largest: _maps(m['largest']).map(InsightRow.fromJson).toList(),
      options: SpendingFilterOptions.fromJson(m['options']),
      earliestCustomStart: _date(m['earliestCustomStart']),
    );
  }

  final InsightPeriod period;
  final InsightPeriod previous;
  final double total;
  final int count;
  final double average;
  final double previousTotal;
  final double? change;
  final double shareOfAll;

  /// The period before starts ahead of the recorded history: not compared.
  final bool previousIncomplete;

  /// Weekly buckets (31 days or less), else monthly.
  final bool byWeek;
  final List<SpendBucket> trend;
  final ({String current, String previous, double currentTotal, double previousTotal, double? change})? monthOverMonth;
  final List<String> summary;

  /// Every matching expense, newest first.
  final List<String> ids;

  /// Some expense carries several tags, so tag groups overlap.
  final bool multiTagged;

  /// 'tag', 'category', 'merchant' and 'source' → groups, largest first.
  final Map<String, List<SpendGroup>> groups;
  final List<InsightRow> largest;
  final SpendingFilterOptions options;
  final DateTime earliestCustomStart;
}

/// A category's or tag's month-by-month average.
class TrendLine {
  const TrendLine({
    required this.key,
    required this.label,
    required this.average,
    required this.previousAverage,
    required this.change,
    required this.months,
    required this.ids,
    this.color,
  });

  factory TrendLine.fromJson(Map<String, Object?> m) => TrendLine(
        key: _str(m['key']),
        label: _str(m['label']),
        average: _num(m['average']),
        previousAverage: _numOrNull(m['previousAverage']),
        change: _numOrNull(m['change']),
        months: m['months'] is List ? (m['months']! as List<Object?>).map(_num).toList() : const <double>[],
        ids: _strings(m['ids']),
        color: _strOrNull(m['color']),
      );

  final String key;
  final String label;
  final double average;
  final double? previousAverage;
  final double? change;

  /// One figure per month of the span, oldest first.
  final List<double> months;
  final List<String> ids;
  final String? color;
}

/// The long view over a span of months.
class AnalyticsView {
  const AnalyticsView({
    required this.range,
    required this.patternCount,
    required this.patternSentences,
    required this.classifiedShare,
    required this.necessity,
    required this.week,
    required this.size,
    required this.topCategoriesShare,
    required this.recurringShare,
    required this.averageSpent,
    required this.change,
    required this.months,
    required this.averages,
    required this.trendSentences,
    required this.cashflowSentences,
    required this.categoryTrends,
    required this.tagTrends,
    required this.cashflow,
    required this.cardUses,
    required this.cardShare,
    required this.cardCharged,
    required this.cardBack,
    required this.cardPurchaseIds,
  });

  factory AnalyticsView.fromJson(Map<String, Object?> m) {
    final Map<String, Object?> p = _map(m['patterns']);
    final Map<String, Object?> t = _map(m['trends']);
    final Map<String, Object?> c = _map(m['cards']);
    final Map<String, Object?> week = _map(p['week']);
    final Map<String, Object?> size = _map(p['size']);
    final Map<String, Object?> flow = _map(t['cashflow']);
    return AnalyticsView(
      range: InsightPeriod.fromJson(m['range']),
      patternCount: _int(p['count']),
      patternSentences: _strings(p['sentences']),
      classifiedShare: _num(p['classifiedShare']),
      necessity: _maps(p['necessity'])
          .map((Map<String, Object?> n) => (key: _str(n['key']), name: _str(n['name']), total: _num(n['total']), share: _num(n['share']), ids: _strings(n['ids'])))
          .toList(),
      week: week.isEmpty ? null : (weekdayPerDay: _num(week['weekdayPerDay']), weekendPerDay: _num(week['weekendPerDay'])),
      size: size.isEmpty ? null : (typical: _num(size['typical']), largeCount: _int(size['largeCount']), largeIds: _strings(size['largeIds'])),
      topCategoriesShare: _num(p['topCategoriesShare']),
      recurringShare: _num(p['recurringShare']),
      averageSpent: _num(t['averageSpent']),
      change: _numOrNull(t['change']),
      months: _maps(t['months'])
          .map((Map<String, Object?> f) => (month: _date(f['month']), spent: _num(f['spent']), income: _num(f['income']), partial: _bool(f['partial'])))
          .toList(),
      averages: _maps(t['averages']).map((Map<String, Object?> a) => (span: _int(a['span']), average: _num(a['average']))).toList(),
      trendSentences: _strings(t['sentences']),
      cashflowSentences: _strings(t['cashflowSentences']),
      categoryTrends: _maps(t['categories']).map(TrendLine.fromJson).toList(),
      tagTrends: _maps(t['tags']).map(TrendLine.fromJson).toList(),
      cashflow: (
        income: _num(flow['income']),
        spent: _num(flow['spent']),
        saved: _num(flow['saved']),
        rate: _numOrNull(flow['rate']),
        overspentMonths: _int(flow['overspentMonths']),
      ),
      cardUses: _maps(c['uses'])
          .map((Map<String, Object?> u) => (id: _str(u['id']), name: _str(u['name']), utilisation: _num(u['utilisation'])))
          .toList(),
      cardShare: _numOrNull(c['cardShare']),
      cardCharged: _num(c['charged']),
      cardBack: _num(c['back']),
      cardPurchaseIds: _strings(c['purchaseIds']),
    );
  }

  final InsightPeriod range;
  final int patternCount;
  final List<String> patternSentences;

  /// Share of spending whose category says essential or discretionary.
  final double classifiedShare;
  final List<({String key, String name, double total, double share, List<String> ids})> necessity;
  final ({double weekdayPerDay, double weekendPerDay})? week;
  final ({double typical, int largeCount, List<String> largeIds})? size;
  final double topCategoriesShare;
  final double recurringShare;
  final double averageSpent;
  final double? change;

  /// The span's complete months, oldest first, then the month running.
  final List<({DateTime month, double spent, double income, bool partial})> months;
  final List<({int span, double average})> averages;
  final List<String> trendSentences;
  final List<String> cashflowSentences;
  final List<TrendLine> categoryTrends;
  final List<TrendLine> tagTrends;
  final ({double income, double spent, double saved, double? rate, int overspentMonths}) cashflow;
  final List<({String id, String name, double utilisation})> cardUses;

  /// Card purchases as a share of spending in the range; null without spending.
  final double? cardShare;

  /// Fees and interest, and refunds and cashback, over the last 12 months.
  final double cardCharged;
  final double cardBack;
  final List<String> cardPurchaseIds;
}
