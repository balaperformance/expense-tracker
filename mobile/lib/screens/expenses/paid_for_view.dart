import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../../models/receivable.dart';
import '../../providers/receivable_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/hero_surface.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';

/// Which of the things paid for someone are listed.
enum PaidForShow {
  open('Still owed'),
  settled('Settled'),
  all('All');

  const PaidForShow(this.label);

  final String label;
}

/// The expense list's "Paid for someone" view: everything paid for someone —
/// purchases made for them and money lent to them — with what has come back
/// and what is still owed, person by person. None of it is the user's
/// spending, and money paid back is not income. The web app's PaidForView.
class PaidForView extends StatelessWidget {
  const PaidForView({
    super.key,
    required this.provider,
    required this.show,
    required this.onShow,
    required this.search,
    required this.accounts,
    required this.cards,
    required this.currency,
    required this.onRefresh,
    required this.onOpen,
    required this.onRepay,
  });

  final ReceivableProvider provider;
  final PaidForShow show;
  final ValueChanged<PaidForShow> onShow;

  /// The expense list's search: matches the person or what was paid.
  final String search;
  final List<BankAccount> accounts;
  final List<CreditCard> cards;
  final String currency;
  final Future<void> Function() onRefresh;
  final ValueChanged<ClaimSummary> onOpen;
  final ValueChanged<ClaimSummary> onRepay;

  @override
  Widget build(BuildContext context) {
    if (provider.isInitialLoad || (provider.isIdle && provider.claims.isEmpty)) {
      return const ListSkeleton(rows: 4);
    }
    if (provider.hasError && provider.claims.isEmpty) {
      return ScrollableCentered(
        child: ErrorView(
          message: provider.errorMessage ?? 'Could not load what you are owed.',
          onRetry: onRefresh,
        ),
      );
    }
    final List<ClaimSummary> all = provider.claims;
    if (all.isEmpty) {
      return const ScrollableCentered(
        child: EmptyState(
          icon: Icons.handshake_outlined,
          title: 'Nothing paid for anyone yet',
          message: "Paid for someone's purchase, or lent them money? Add it as an "
              'expense and turn on “Paid for someone else”. It stays out of '
              'your spending, and you record each repayment on it until it is '
              'settled.',
        ),
      );
    }

    final String wanted = personKey(search);
    final List<ClaimSummary> matching = wanted.isEmpty
        ? all
        : all
            .where((ClaimSummary c) =>
                personKey(c.receivable.person).contains(wanted) ||
                personKey(c.source?.title).contains(wanted))
            .toList();
    final List<ClaimSummary> shown = matching
        .where((ClaimSummary c) => switch (show) {
              PaidForShow.all => true,
              PaidForShow.open => c.status.isOpen,
              PaidForShow.settled => !c.status.isOpen,
            })
        .toList();
    final List<PersonBalance> groups = balancesByPerson(shown);
    final int people = balancesByPerson(all).where((PersonBalance p) => p.open > 0).length;
    final DateTime today = AppDateUtils.today();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.sm,
        AppSpacing.page,
        AppSpacing.bottomListPadding,
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
          message: 'Purchases you paid for others and money you lent. Not '
              'your spending — and money paid back is not income.',
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<PaidForShow>(
            segments: <ButtonSegment<PaidForShow>>[
              for (final PaidForShow s in PaidForShow.values)
                ButtonSegment<PaidForShow>(value: s, label: Text(s.label)),
            ],
            selected: <PaidForShow>{show},
            showSelectedIcon: false,
            onSelectionChanged: (Set<PaidForShow> value) => onShow(value.first),
          ),
        ),
        const SizedBox(height: AppSpacing.section),
        if (groups.isEmpty)
          EmptyState(
            compact: true,
            icon: Icons.handshake_outlined,
            title: 'Nothing here',
            message: wanted.isNotEmpty
                ? 'Nothing paid for anyone matches your search.'
                : show == PaidForShow.open
                    ? 'Everything has been paid back.'
                    : 'Nothing settled yet.',
          )
        else
          for (final PersonBalance group in groups) ...<Widget>[
            _PersonHeader(group: group, currency: currency),
            for (final ClaimSummary claim in group.claims) ...<Widget>[
              PaidForCard(
                claim: claim,
                currency: currency,
                from: fromLabel(claim, accounts, cards),
                today: today,
                onOpen: () => onOpen(claim),
                onRepay: () => onRepay(claim),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            const SizedBox(height: AppSpacing.sm),
          ],
      ],
    );
  }

  /// Where the money came from: a card, an account, or cash.
  static String? fromLabel(
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

/// One thing paid for someone: what went out, each repayment, what is left,
/// and a button to record the next one. On the expense's own page [onOpen] is
/// null and the card names the person instead of the purchase.
class PaidForCard extends StatelessWidget {
  const PaidForCard({
    super.key,
    required this.claim,
    required this.currency,
    required this.today,
    required this.onRepay,
    this.from,
    this.onOpen,
  });

  final ClaimSummary claim;
  final String currency;

  /// Where the money came from: an account, a card or cash.
  final String? from;
  final DateTime today;
  final VoidCallback? onOpen;
  final VoidCallback? onRepay;

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
    final String title = onOpen != null ? (source?.title ?? 'Paid for them') : claim.receivable.title;
    final String meta = <String>[
      if (source != null)
        Formatters.dayMonthYear(source.date)
      else
        'What was paid is no longer available',
      if (from != null) from!,
    ].join(' · ');
    final double ratio = claim.principal > 0 ? claim.received / claim.principal : 0;
    final String? note = claim.receivable.note?.trim();

    final Widget head = Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          IconWell(icon: Icons.handshake_outlined, tone: ToneColors.transfer(context)),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
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
                amountLeft(claim),
                currency: currency,
                tone: settled ? AmountTone.neutral : AmountTone.transfer,
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
    );

    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (onOpen != null)
            Semantics(
              button: true,
              label: 'Open $title, paid for ${claim.receivable.person}',
              child: InkWell(onTap: onOpen, child: head),
            )
          else
            head,
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
                        'more than was paid',
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
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
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
                if (!settled && source != null && onRepay != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  Align(
                    alignment: Alignment.centerRight,
                    child: AppButton(
                      label: 'Record repayment',
                      icon: Icons.add_rounded,
                      size: AppButtonSize.small,
                      variant: AppButtonVariant.tonal,
                      onPressed: onRepay,
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
