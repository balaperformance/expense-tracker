/// The one place bank-SMS import is allowed to consult the AI.
///
/// It is an optional refinement of a draft that is already complete: by the
/// time this runs the amount, account, date and a fallback category are all
/// settled, so a failure, an outage or a nonsense answer costs nothing.
///
/// Four rules, all enforced here rather than trusted to the model:
///
///  * It is asked only when the on-device keyword rules found nothing. A
///    recognised merchant never leaves the device at all.
///  * Only the payee is sent. Not the message, the amount, the account, the
///    reference or the balance.
///  * The answer must be one of the user's own category names. Anything else
///    is discarded rather than created.
///  * It never fails loudly. No answer simply leaves the draft as it was.
library;

import '../../models/expense_category.dart';
import '../ai/ai_chat_service.dart';
import 'sms_expense_draft.dart';

class SmsCategoryAssistant {
  const SmsCategoryAssistant(this._service);

  final AiChatService _service;

  /// Returns [draft] with a better category, or unchanged.
  Future<SmsExpenseDraft> refine({
    required SmsExpenseDraft draft,
    required List<ExpenseCategory> categories,
  }) async {
    if (!shouldAsk(draft: draft, categories: categories)) return draft;

    final String merchant = draft.merchant!;

    String? name;
    try {
      name = await _service.suggestCategory(merchant: merchant);
    } catch (_) {
      // The service already promises not to throw. Catching anyway costs
      // nothing and means a future implementation that breaks that promise
      // degrades to "no suggestion" instead of killing an import the user
      // had already finished the hard part of.
      return draft;
    }

    // Checked against the user's own list, so a model that invents
    // "Locksmiths" or answers a different question changes nothing.
    final ExpenseCategory? suggested =
        SmsDraftBuilder.categoryByName(categories, name);
    if (suggested == null) return draft;

    return draft.copyWith(
      categoryId: suggested.id,
      categorySource: SmsCategorySource.assistant,
      categoryReason: 'suggested for "$merchant"',
    );
  }

  /// Whether asking is worthwhile at all.
  ///
  /// Separated from [refine] so the rule is visible on its own, and so a test
  /// can assert the common case never reaches the network.
  static bool shouldAsk({
    required SmsExpenseDraft draft,
    required List<ExpenseCategory> categories,
  }) {
    if (draft.merchant == null) return false;
    if (draft.categorySource == SmsCategorySource.keyword) return false;
    if (categories.isEmpty) return false;
    return true;
  }
}
