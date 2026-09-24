import { useState, type CSSProperties } from 'react';

import { Page } from '@/components/layout/Page';
import { CategoryAvatar } from '@/components/finance/Avatars';
import { Button, Fab, IconButton } from '@/components/ui/Button';
import { Centered, EmptyState, ErrorView, InlineError, ListSkeleton, Notice } from '@/components/ui/Feedback';
import { FieldLabel, TextField } from '@/components/ui/Fields';
import { CategoryGlyph, Icon } from '@/components/ui/Icon';
import { Sheet } from '@/components/ui/Sheet';
import { CardList, ListRow, SectionHeader } from '@/components/ui/Surface';
import { CATEGORY_ICON_NAMES } from '@/domain/defaults';
import type { ExpenseCategory } from '@/domain/models';
import { useCategories } from '@/hooks/data';
import { useIsDark } from '@/hooks/useIsDark';
import { useSheet } from '@/hooks/useSheet';
import { useDeleteCategory, useSaveCategory } from '@/hooks/mutations';
import { CATEGORY_SWATCHES, prefersLightInk, readableOn } from '@/lib/color';
import { errorMessage } from '@/lib/errors';
import { validateRequired } from '@/lib/validators';
import { countUsingCategory } from '@/services/expenses';
import { useUserId } from '@/state/auth';
import { useFeedback } from '@/state/feedback';

import styles from './Catalog.module.css';

export function CategoriesPage() {
  const userId = useUserId();
  const { toast, confirm } = useFeedback();
  const categories = useCategories();
  const remove = useDeleteCategory();
  const editor = useSheet<ExpenseCategory | null>();
  const list = categories.data ?? [];

  const confirmDelete = async (category: ExpenseCategory) => {
    const usage = await countUsingCategory(userId, category.id);
    const consequence =
      usage === 0
        ? 'No expenses use this category.'
        : `${usage} ${usage === 1 ? 'expense keeps' : 'expenses keep'} their amount but become uncategorised.`;
    const ok = await confirm({ title: `Delete "${category.name}"?`, message: `${consequence} This cannot be undone.` });
    if (!ok) return;
    try {
      await remove.mutateAsync(category.id);
      toast('success', 'Category deleted');
    } catch (error) {
      toast('error', errorMessage(error, 'Could not delete the category.'));
    }
  };

  let body;
  if (categories.isPending) body = <ListSkeleton rows={7} />;
  else if (categories.isError && !list.length) {
    body = (
      <Centered>
        <ErrorView message={errorMessage(categories.error)} onRetry={() => void categories.refetch()} />
      </Centered>
    );
  } else if (!list.length) {
    body = (
      <Centered>
        <EmptyState icon="category" title="No categories" message="Create categories to organise your spending." actionLabel="Add category" onAction={() => editor.open(null)} />
      </Centered>
    );
  } else {
    body = (
      <>
        <div>
          <SectionHeader title="Categories" caption={String(list.length)} />
          <CardList>
            {list.map((category) => (
              <ListRow
                key={category.id}
                dense
                leading={<CategoryAvatar icon={category.icon} color={category.color} />}
                title={category.name}
                subtitle={category.isDefault ? 'Default' : undefined}
                onClick={() => editor.open(category)}
                action={
                  <IconButton icon="delete" label={`Delete ${category.name}`} small color="var(--muted)" onClick={() => void confirmDelete(category)} />
                }
              />
            ))}
          </CardList>
        </div>
        <Notice message="Tap a category to rename it or change its icon and colour." />
      </>
    );
  }

  return (
    <Page title="Categories" back="/settings" narrow>
      {body}
      <Fab label="New" onClick={() => editor.open(null)} />
      <CategoryEditorSheet key={editor.key} open={editor.isOpen} category={editor.data} onClose={editor.close} />
    </Page>
  );
}

function CategoryEditorSheet({ open, category, onClose }: { open: boolean; category: ExpenseCategory | null; onClose: () => void }) {
  const dark = useIsDark();
  const save = useSaveCategory();
  const [name, setName] = useState(category?.name ?? '');
  const [icon, setIcon] = useState(category?.icon ?? 'category');
  const [color, setColor] = useState<string>(category?.color ?? CATEGORY_SWATCHES[0]);
  const [nameError, setNameError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const tint = readableOn(color, dark);

  const submit = async () => {
    const problem = validateRequired(name, 'Name');
    setNameError(problem);
    if (problem) return;
    setError(null);
    try {
      await save.mutateAsync({ id: category?.id, draft: { name, icon, color } });
      onClose();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not save the category.'));
    }
  };

  return (
    <Sheet
      open={open}
      onClose={onClose}
      busy={save.isPending}
      title={category ? 'Edit category' : 'New category'}
      subtitle="Name, colour and icon"
      action={<CategoryAvatar icon={icon} color={color} size={40} />}
      footer={<Button label={category ? 'Save changes' : 'Add category'} size="lg" block busy={save.isPending} busyLabel="Saving…" onClick={() => void submit()} />}
    >
      <div>
        <FieldLabel text="Name" required />
        <TextField value={name} onChange={setName} placeholder="Groceries, Rent…" aria-label="Name" autoCapitalize="words" disabled={save.isPending} error={nameError} />
      </div>
      <div>
        <FieldLabel text="Colour" />
        <div className={styles.swatches} role="radiogroup" aria-label="Colour">
          {CATEGORY_SWATCHES.map((hex) => {
            const swatch = readableOn(hex, dark);
            const selected = hex.toUpperCase() === color.toUpperCase();
            return (
              <button
                key={hex}
                type="button"
                role="radio"
                aria-checked={selected}
                aria-label={hex}
                className={[styles.swatch, selected && styles.swatchOn].filter(Boolean).join(' ')}
                style={{ background: swatch }}
                onClick={() => setColor(hex)}
                disabled={save.isPending}
              >
                {selected ? <Icon name="check" size={17} color={prefersLightInk(swatch) ? '#fff' : 'rgb(0 0 0 / 0.87)'} /> : null}
              </button>
            );
          })}
        </div>
      </div>
      <div>
        <FieldLabel text="Icon" />
        <div className={styles.icons} role="radiogroup" aria-label="Icon">
          {CATEGORY_ICON_NAMES.map((iconName) => (
            <button
              key={iconName}
              type="button"
              role="radio"
              aria-checked={iconName === icon}
              aria-label={iconName.replace(/_/g, ' ')}
              className={[styles.iconChoice, iconName === icon && styles.iconChoiceOn].filter(Boolean).join(' ')}
              style={{ '--tone': tint } as CSSProperties}
              onClick={() => setIcon(iconName)}
              disabled={save.isPending}
            >
              <CategoryGlyph icon={iconName} size={20} />
            </button>
          ))}
        </div>
      </div>
      {error ? <InlineError message={error} /> : null}
    </Sheet>
  );
}
