import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../../models/expense.dart';
import '../../models/receivable.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/receivable_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/hero_surface.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../expenses/expense_form_screen.dart';
import 'account_statement_screen.dart';

/// Which claims are listed.
enum _Show {
  open('Still owed'),
  settled('Settled'),
  all('All');

  const _Show(this.label);

  final String label;
}

/// Money owed to you: what you lent, and what you paid for others. None of it
/// is income or spending — the balance moved when the money went out and
/// comes back as each repayment arrives. The web app's "Owed to you" page.
///
/// Read-only, as on the web: a loan is recorded, and a repayment matched to
/// a claim, from the account statement; a purchase is marked on the expense.
/// Tapping a claim opens where its money went out.
class ReceivablesScreen extends StatefulWidget {
  const ReceivablesScreen({super.key});

  @override
  State<ReceivablesScreen> createState() => _ReceivablesScreenState();
}

class _ReceivablesScreenState extends State<ReceivablesScreen> {
  _Show _show = _Show.open;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(force: true));
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    // The accounts and cards only name where each claim's money came from.
    final BankAccountProvider? accounts = context.read<BankAccountProvider?>();
    final CreditCardProvider? cards = SchemaCapabilities.creditCards
        ? context.read<CreditCardProvider?>()
        : null;
    await Future.wait(<Future<void>>[
      context.read<ReceivableProvider>().load(userId: userId, force: force),
      if (accounts != null) accounts.load(userId: userId),
      if (cards != null) cards.load(userId: userId),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final ReceivableProvider provider = context.watch<ReceivableProvider>();
    final String currency = context.watch<SettingsProvider>().currency;

    return Scaffold(
      appBar: AppBar(title: const Text('Owed to you')),
      body: _body(
        provider,
        currency,
        accounts: context.watch<BankAccountProvider?>()?.accounts ??
            const <BankAccount>[],
        cards: context.watch<CreditCardProvider?>()?.cards ??
            const <CreditCard>[],
      ),
    );
  }

  Widget _body(
    ReceivableProvider provider,
    String currency, {
    required List<BankAccount> accounts,
    required List<CreditCard> cards,
  }) {
    if (!SchemaCapabilities.treatments) {
      return const ScrollableCentered(
        child: EmptyState(
          icon: Icons.dataset_outlined,
          title: 'One migration away',
          message: 'Loans and reimbursements need '
              'ui/supabase/005_transaction_treatments.sql. Run it in the '
              'Supabase SQL editor; everything else keeps working without it.',
        ),
      );
    }
    if (provider.isInitialLoad || (provider.isIdle && provider.claims.isEmpty)) {
      return const ListSkeleton(rows: 4);
    }
    if (provider.hasError && provider.claims.isEmpty) {
      return ScrollableCentered(
        child: ErrorView(
          message: provider.errorMessage ?? 'Could not load what you are owed.',
          onRetry: () => _load(force: true),
        ),
      );
    }

    final List<ClaimSummary> all = provider.claims;
    if (all.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: const ScrollableCentered(
          child: EmptyState(
            icon: Icons.handshake_outlined,
            title: 'Nobody owes you anything',
            message: 'On an account statement, tap money you lent and record '
                'it as a Loan. On an expense, turn on “Paid for someone '
                'else”. Repayments are matched to them the same way.',
          ),
        ),
      );
    }

    final List<ClaimSummary> shown = all
        .where((ClaimSummary c) => switch (_show) {
              _Show.all => true,
              _Show.open => c.status.isOpen,
              _Show.settled => !c.status.isOpen,
            })
        .toList();
    final List<PersonBalance> groups = balancesByPerson(shown);
    final int people =
        balancesByPerson(all).where((PersonBalance p) => p.open > 0).length;
    final DateTime today = AppDateUtils.today();

    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.sm,
          AppSpacing.page,
          AppSpacing.bottomListPaddingPage,
        ),
        children: <Widget>[
          _OwedTotal(
            owed: provider.outstanding,
            openCount: provider.openCount,
            people: people,
            currency: currency,
          ),
          const SizedBox(height: AppSpacing.md),
          const AppNotice(
            message: 'Not income or spending: your balance went down when the '
                'money went out, and goes up as it comes back.',
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<_Show>(
              segments: <ButtonSegment<_Show>>[
                for (final _Show s in _Show.values)
                  ButtonSegment<_Show>(value: s, label: Text(s.label)),
              ],
              selected: <_Show>{_show},
              showSelectedIcon: false,
              onSelectionChanged: (Set<_Show> value) =>
                  setState(() => _show = value.first),
            ),
          ),
          const SizedBox(height: AppSpacing.section),
          if (groups.isEmpty)
            EmptyState(
              compact: true,
              icon: Icons.handshake_outlined,
              title: 'Nothing here',
              message: _show == _Show.open
                  ? 'Everything has been paid back.'
                  : 'Nothing settled yet.',
            )
          else
            for (final PersonBalance group in groups) ...<Widget>[
              _PersonHeader(group: group, currency: currency),
              for (final ClaimSummary claim in group.claims) ...<Widget>[
                _ClaimCard(
                  claim: claim,
                  currency: currency,
                  from: _fromLabel(claim, accounts, cards),
                  today: today,
                  onOpen: _opening ? null : () => _open(claim),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              const SizedBox(height: AppSpacing.sm),
            ],
        ],
      ),
    );
  }

  /// Where the money came from: a card, an account, or cash.
  static String? _fromLabel(
    ClaimSummary claim,
    List<BankAccount> accounts,
    List<CreditCard> cards,
  ) {
    final ClaimSource? source = claim.source;
    if (source == null) return null;
    final String? cardId = source.cardId;
    if (cardId != null) {
      for (final CreditCard card in cards) {
        if (card.id == cardId) return card.displayLabel;
      }
      return 'Credit card';
    }
    final String? accountId = source.accountId;
    if (accountId != null) {
      for (final BankAccount account in accounts) {
        if (account.id == accountId) return account.displayLabel;
      }
      return null;
    }
    return 'Cash';
  }

  /// Where the money went out: the expense, or the account statement.
  Future<void> _open(ClaimSummary claim) async {
    final ClaimSource? source = claim.source;
    final String? userId = context.read<AuthProvider>().userId;
    if (source == null || userId == null) return;
    final String? expenseId = source.expenseId;
    final String? accountId = source.accountId;

    if (claim.receivable.kind == ReceivableKind.reimbursable &&
        expenseId != null) {
      setState(() => _opening = true);
      Expense? expense;
      try {
        expense = await context
            .read<ExpenseProvider>()
            .fetchById(userId: userId, id: expenseId);
      } catch (_) {
        expense = null;
      }
      if (!mounted) return;
      setState(() => _opening = false);
      if (expense == null) {
        AppFeedback.error(context, 'That expense could not be opened.');
        return;
      }
      final Expense found = expense;
      final bool? changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => ExpenseFormScreen(expense: found),
        ),
      );
      if (changed == true && mounted) await _load(force: true);
      return;
    }

    if (accountId != null) {
      BankAccount? account;
      for (final BankAccount a
          in context.read<BankAccountProvider?>()?.accounts ??
              const <BankAccount>[]) {
        if (a.id == accountId) account = a;
      }
      if (account == null) {
        AppFeedback.error(context, 'That account is no longer available.');
        return;
      }
      final BankAccount found = account;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => AccountStatementScreen(account: found),
        ),
      );
      // A repayment may have been matched on the statement.
      if (mounted) await _load(force: true);
    }
  }
}

/// The total still owed, and by how many people.
class _OwedTotal extends StatelessWidget {
  const _OwedTotal({
    required this.owed,
    required this.openCount,
    required this.people,
    required this.currency,
  });

  final double owed;
  final int openCount;
  final int people;
  final String currency;

  @override
  Widget build(BuildContext context) {
    // Builder so everything inside reads the hero's dark theme.
    return HeroSurface(child: Builder(builder: _content));
  }

  Widget _content(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = PaletteTokens.of(context).heroAccent;

    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'OWED TO YOU',
                style: AppTypography.eyebrow(theme.textTheme, color: accent),
              ),
              const SizedBox(height: AppSpacing.xs),
              MoneyText(
                owed,
                currency: currency,
                fit: true,
                style: theme.textTheme.displaySmall,
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                openCount > 0
                    ? '$openCount open · $people '
                        '${people == 1 ? 'person' : 'people'}'
                    : 'Everything has been paid back',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        IconWell(icon: Icons.handshake_outlined, tone: accent, size: 44),
      ],
    );
  }
}

/// A person's name and what they still owe.
class _PersonHeader extends StatelessWidget {
  const _PersonHeader({required this.group, required this.currency});

  final PersonBalance group;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        0,
        AppSpacing.xs,
        AppSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              group.person,
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (group.outstanding > 0) ...<Widget>[
            const SizedBox(width: AppSpacing.sm),
            Text('owes ', style: theme.textTheme.labelMedium),
            MoneyText(
              group.outstanding,
              currency: currency,
              style: theme.textTheme.labelMedium,
            ),
          ],
        ],
      ),
    );
  }
}

/// One claim: where it came from, what is left, and every repayment.
class _ClaimCard extends StatelessWidget {
  const _ClaimCard({
    required this.claim,
    required this.currency,
    required this.from,
    required this.today,
    required this.onOpen,
  });

  final ClaimSummary claim;
  final String currency;
  final String? from;
  final DateTime today;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ClaimSource? source = claim.source;
    final String? due = dueText(claim, today);
    final bool settled = !claim.status.isOpen;
    final Color tone = settled
        ? ToneColors.income(context)
        : claim.overdue
            ? ToneColors.warning(context)
            : ToneColors.transfer(context);
    final String meta = <String>[
      if (source != null)
        '${source.title} · ${Formatters.dayMonthYear(source.date)}'
      else
        'Its source is no longer available',
      if (from != null) from!,
    ].join(' · ');
    final double ratio =
        claim.principal > 0 ? claim.received / claim.principal : 0;
    final String? note = claim.receivable.note?.trim();

    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            button: true,
            label: 'Open ${claim.receivable.title}',
            excludeSemantics: false,
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.sm,
                ),
                child: Row(
                  children: <Widget>[
                    IconWell(
                      icon: Icons.handshake_outlined,
                      tone: ToneColors.transfer(context),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            claim.receivable.title,
                            style: theme.textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: AppSpacing.xxs),
                          Text(
                            meta,
                            style: theme.textTheme.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        MoneyText(
                          claim.outstanding < 0 ? 0 : claim.outstanding,
                          currency: currency,
                          tone: settled
                              ? AmountTone.neutral
                              : AmountTone.transfer,
                          emphasis: true,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          'of ${Formatters.currency(claim.principal, currencyCode: currency)}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
                  child: LinearProgressIndicator(
                    value: ratio.clamp(0, 1).toDouble(),
                    minHeight: 6,
                    color: tone,
                    backgroundColor: ToneColors.wash(context, tone),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    AppBadge(
                      label: claim.status.label,
                      icon: settled ? Icons.check_circle_rounded : null,
                      tone: tone,
                    ),
                    if (due != null)
                      AppBadge(
                        label: due,
                        icon: Icons.event_outlined,
                        tone: claim.overdue ? ToneColors.warning(context) : null,
                      ),
                    if (claim.status == ClaimStatus.overpaid)
                      Text(
                        '${Formatters.currency(-claim.outstanding, currencyCode: currency)} '
                        'more than lent',
                        style: theme.textTheme.labelSmall,
                      ),
                    if (note != null && note.isNotEmpty)
                      Text('· $note', style: theme.textTheme.labelSmall),
                  ],
                ),
                if (claim.repayments.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  const Divider(height: 1),
                  const SizedBox(height: AppSpacing.xs),
                  for (final ClaimRepayment r in claim.repayments)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.xxs,
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '${Formatters.dayMonthYear(r.date)} · '
                              '${(r.description?.trim().isNotEmpty ?? false) ? r.description!.trim() : 'Repayment'}',
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          MoneyText(
                            r.amount,
                            currency: currency,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
