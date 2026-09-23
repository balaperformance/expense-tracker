import 'dart:ui' show Rect;

import '../core/errors/app_exception.dart';
import '../models/bank_account.dart';
import '../models/expense_category.dart';
import '../models/payment_method.dart';
import '../repositories/export_repository.dart';
import '../services/export/export_dataset_builder.dart';
import '../services/export/export_models.dart';
import '../services/export/export_service.dart';
import 'async_state.dart';

/// Reference data the builder needs, supplied by the screen from the
/// providers that already hold it.
///
/// Passed in rather than injected so the export provider does not have to
/// depend on four other providers, and so a preview can be rebuilt from a
/// consistent snapshot rather than from whatever happened to be loaded when
/// each lookup fired.
class ExportReferenceData {
  const ExportReferenceData({
    required this.currencyCode,
    required this.accounts,
    required this.categories,
    required this.paymentMethods,
  });

  final String currencyCode;
  final List<BankAccount> accounts;
  final List<ExpenseCategory> categories;
  final List<PaymentMethod> paymentMethods;

  BankAccount? accountById(String? id) {
    if (id == null) return null;
    for (final BankAccount account in accounts) {
      if (account.id == id) return account;
    }
    return null;
  }
}

/// Drives the export screen: the choices, the preview, and the file.
///
/// Splitting preview from export matters. Building the dataset is the
/// expensive part and the part that can come back empty, so the user sees the
/// real figures — and an honest "nothing to export" — before committing to a
/// format and a share sheet.
class ExportProvider extends AsyncProvider {
  ExportProvider({
    required ExportRepository repository,
    ExportService? service,
    ExportDatasetBuilder builder = const ExportDatasetBuilder(),
  })  : _repository = repository,
        _service = service ?? ExportService(),
        _builder = builder;

  final ExportRepository _repository;
  final ExportService _service;
  final ExportDatasetBuilder _builder;

  ExportRequest _request = ExportRequest(
    type: ExportReportType.expenses,
    range: ExportDateRange.month(DateTime.now()),
    format: ExportFormat.pdf,
  );

  ExportDataset? _preview;
  ExportSource? _source;
  bool _exporting = false;
  ExportResult? _lastResult;

  ExportRequest get request => _request;
  ExportDataset? get preview => _preview;
  bool get exporting => _exporting;
  ExportResult? get lastResult => _lastResult;

  /// True when the chosen period genuinely holds nothing.
  bool get isEmptyResult => isReady && (_preview?.hasRows == false);

  /// True when the query hit its row cap, so the report is partial.
  bool get isTruncated => _source?.truncated ?? false;

  @override
  bool get isEmptyData => _preview == null;

  // -------------------------------------------------------------------
  // Choices
  // -------------------------------------------------------------------

  /// Sets up the screen. [presetAccountId] comes from the contextual entry
  /// points — exporting from a statement should already have that account
  /// chosen.
  void start({
    required ExportReportType type,
    String? presetAccountId,
    ExportDateRange? range,
  }) {
    _request = ExportRequest(
      type: type,
      range: range ?? ExportDateRange.month(DateTime.now()),
      format: ExportFormat.pdf,
      accountId: presetAccountId,
    );
    _preview = null;
    _source = null;
    _lastResult = null;
    safeNotify();
  }

  void setType(ExportReportType type) {
    if (_request.type == type) return;
    // Category filters mean nothing on an income or statement export, so they
    // are dropped rather than silently retained and reapplied later.
    _request = _request.copyWith(
      type: type,
      categoryIds: type.supportsCategoryFilter
          ? _request.categoryIds
          : <String>{},
    );
    _invalidatePreview();
  }

  void setRange(ExportDateRange range) {
    if (_request.range == range) return;
    _request = _request.copyWith(range: range);
    _invalidatePreview();
  }

  void setAccount(String? accountId) {
    if (_request.accountId == accountId) return;
    _request = _request.copyWith(
      accountId: accountId,
      clearAccount: accountId == null,
    );
    _invalidatePreview();
  }

  void toggleCategory(String categoryId) {
    final Set<String> next = <String>{..._request.categoryIds};
    if (!next.remove(categoryId)) next.add(categoryId);
    _request = _request.copyWith(categoryIds: next);
    _invalidatePreview();
  }

  void clearCategories() {
    if (_request.categoryIds.isEmpty) return;
    _request = _request.copyWith(categoryIds: <String>{});
    _invalidatePreview();
  }

  /// Format is a rendering choice, so changing it does not throw away a
  /// preview that is already correct.
  void setFormat(ExportFormat format) {
    if (_request.format == format) return;
    _request = _request.copyWith(format: format);
    safeNotify();
  }

  void _invalidatePreview() {
    _preview = null;
    _source = null;
    _lastResult = null;
    safeNotify();
  }

  // -------------------------------------------------------------------
  // Preview
  // -------------------------------------------------------------------

  /// Loads the data and builds the dataset, without writing a file.
  Future<void> loadPreview({
    required String userId,
    required ExportReferenceData reference,
  }) async {
    if (!_request.isRunnable) return;

    setLoading();
    try {
      final BankAccount? account = reference.accountById(_request.accountId);
      final ExportSource source = await _repository.load(
        userId: userId,
        request: _request,
        account: account,
      );

      _source = source;
      _preview = _build(source, reference);
      setReady();
    } catch (error) {
      _preview = null;
      _source = null;
      setError(error);
    }
  }

  ExportDataset _build(ExportSource source, ExportReferenceData reference) {
    final ExportContext context = ExportContext(
      currencyCode: reference.currencyCode,
      accounts: reference.accounts,
      categories: reference.categories,
      paymentMethods: reference.paymentMethods,
    );

    final String? filterNote = _filterNote(reference);

    return switch (_request.type) {
      ExportReportType.bankStatement => _builder.bankStatement(
          account: source.account!,
          statement: source.statement!,
          range: _request.range,
          context: context,
        ),
      ExportReportType.expenses => _builder.expenses(
          expenses: source.expenses,
          range: _request.range,
          context: context,
          filterNote: filterNote,
        ),
      ExportReportType.income => _builder.income(
          income: source.income,
          range: _request.range,
          context: context,
        ),
      ExportReportType.spendingReport => _builder.spendingReport(
          expenses: source.expenses,
          categories: reference.categories,
          range: _request.range,
          context: context,
          filterNote: filterNote,
        ),
      ExportReportType.categoryReport => _builder.categoryReport(
          expenses: source.expenses,
          categories: reference.categories,
          range: _request.range,
          context: context,
          filterNote: filterNote,
        ),
      ExportReportType.incomeVsExpense => _builder.incomeVsExpense(
          expenses: source.expenses,
          income: source.income,
          range: _request.range,
          context: context,
        ),
    };
  }

  /// Says on the report itself that it was filtered, so a narrowed export
  /// cannot later be mistaken for a complete one.
  String? _filterNote(ExportReferenceData reference) {
    if (_request.categoryIds.isEmpty) return null;

    final List<String> names = <String>[
      for (final ExpenseCategory category in reference.categories)
        if (_request.categoryIds.contains(category.id)) category.name,
    ];
    if (names.isEmpty) return null;
    return 'Filtered to ${names.join(', ')}';
  }

  // -------------------------------------------------------------------
  // Export
  // -------------------------------------------------------------------

  /// Renders the previewed dataset and opens the share sheet.
  ///
  /// Returns the written file, or null when it failed — in which case
  /// [errorMessage] says why.
  Future<ExportResult?> exportAndShare({
    required ExportReferenceData reference,
    Rect? shareOrigin,
  }) async {
    final ExportDataset? dataset = _preview;
    if (dataset == null || _exporting) return null;

    _exporting = true;
    clearError();
    safeNotify();

    try {
      final BankAccount? account = reference.accountById(_request.accountId);
      final String fileName = ExportService.fileNameFor(
        type: _request.type,
        range: _request.range,
        format: _request.format,
        qualifier: account?.bankName,
      );

      final ExportResult result = await _service.write(
        dataset: dataset,
        format: _request.format,
        fileName: fileName,
      );
      _lastResult = result;

      await _service.share(result, origin: shareOrigin);
      return result;
    } catch (error) {
      setErrorMessage(ErrorMapper.map(error).message);
      return null;
    } finally {
      _exporting = false;
      safeNotify();
    }
  }

  /// Records a failure without blanking the preview the user is looking at.
  ///
  /// `setError` would flip the whole screen into its error state and throw
  /// away a perfectly good preview just because the share sheet did not open.
  void setErrorMessage(String message) {
    _failure = message;
    safeNotify();
  }

  String? _failure;

  /// The export-time failure, separate from the load failure [errorMessage]
  /// reports.
  String? get exportError => _failure;

  /// Clears both failures.
  ///
  /// The notify is explicit rather than delegated: the base implementation
  /// returns early when its own message is already null, which would leave a
  /// stale export error on screen after it had been cleared here.
  @override
  void clearError() {
    final bool hadExportError = _failure != null;
    _failure = null;
    super.clearError();
    if (hadExportError) safeNotify();
  }

  void reset() {
    _preview = null;
    _source = null;
    _lastResult = null;
    _failure = null;
    _exporting = false;
    safeNotify();
  }
}
