import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../providers/auth_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/income_provider.dart';
import '../../providers/tag_provider.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';

/// The user's hashtags, each with how many transactions use it, and a delete.
///
/// A tag that something uses is deleted only after asking: those
/// transactions are untagged from it and moved to "Others" (migration 020),
/// so none is left without a hashtag by the delete.
class HashtagsScreen extends StatefulWidget {
  const HashtagsScreen({super.key});

  @override
  State<HashtagsScreen> createState() => _HashtagsScreenState();
}

class _HashtagsScreenState extends State<HashtagsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = true}) async {
    final String? userId = context.read<AuthProvider>().userId;
    if (!mounted || userId == null) return;
    await context.read<TagProvider>().load(userId: userId, force: force);
  }

  @override
  Widget build(BuildContext context) {
    final TagProvider provider = context.watch<TagProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Hashtags')),
      body: _body(context, provider),
    );
  }

  Widget _body(BuildContext context, TagProvider provider) {
    if (provider.isInitialLoad || provider.isIdle) {
      return const ListSkeleton(rows: 5);
    }
    if (provider.hasError && provider.entries.isEmpty) {
      return ScrollableCentered(
        child: ErrorView(
          message: provider.errorMessage!,
          onRetry: _load,
        ),
      );
    }
    if (provider.entries.isEmpty) {
      return const ScrollableCentered(
        child: EmptyState(
          icon: Icons.tag_rounded,
          title: 'No hashtags',
          message: 'Tags you add to expenses and income show up here.',
        ),
      );
    }

    final ThemeData theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.md,
          AppSpacing.page,
          AppSpacing.bottomListPaddingPage,
        ),
        children: <Widget>[
          SectionHeader(
            title: 'Hashtags',
            caption: '${provider.entries.length}',
          ),
          CardList(
            dividerIndent: AppSpacing.avatarSm + AppSpacing.md + AppSpacing.md,
            children: <Widget>[
              for (final TagEntry entry in provider.entries)
                AppListRow(
                  leading: IconWell(
                    icon: Icons.tag_rounded,
                    tone: theme.colorScheme.primary,
                    size: AppSpacing.avatarSm,
                  ),
                  title: '#${entry.tag.name}',
                  subtitle: _usage(entry.uses),
                  dense: true,
                  trailing: IconButton(
                    tooltip: 'Delete',
                    onPressed: () => _confirmDelete(context, entry),
                    visualDensity: VisualDensity.compact,
                    color: theme.colorScheme.onSurfaceVariant,
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      size: AppSpacing.iconMd,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const AppNotice(
            message: 'Deleting a hashtag untags the transactions that use it '
                'and moves them to #Others.',
          ),
        ],
      ),
    );
  }

  static String _usage(int uses) => uses == 0
      ? 'Not used'
      : '$uses ${uses == 1 ? 'transaction' : 'transactions'}';

  Future<void> _confirmDelete(BuildContext context, TagEntry entry) async {
    final TagProvider provider = context.read<TagProvider>();
    final String name = entry.tag.name;
    final int uses = await provider.usesNow(entry);
    if (!context.mounted) return;

    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Delete #$name?',
      message: uses == 0
          ? 'No transactions use it.'
          : uses == 1
              ? "1 transaction uses #$name. It'll be untagged and moved to "
                  '#Others, then #$name is deleted.'
              : "$uses transactions use #$name. They'll be untagged and moved "
                  'to #Others, then #$name is deleted.',
      confirmLabel: uses == 0 ? 'Delete' : 'Untag & delete',
    );
    if (!confirmed || !context.mounted) return;

    final int? moved = await provider.delete(entry.tag);
    if (!context.mounted) return;

    if (moved == null) {
      AppFeedback.error(
        context,
        provider.errorMessage ?? 'Could not delete the hashtag.',
      );
      return;
    }
    // Tags on expenses and income changed: what reads them (the lists, the
    // spending and insight reports) reloads.
    context.read<ExpenseProvider>().tagsChanged();
    context.read<IncomeProvider>().tagsChanged();
    AppFeedback.success(
      context,
      moved == 0
          ? 'Hashtag deleted'
          : 'Hashtag deleted · $moved moved to #Others',
    );
  }
}
