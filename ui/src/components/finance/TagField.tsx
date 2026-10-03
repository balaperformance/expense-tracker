import { Chip } from '@/components/ui/Chip';
import { TextField } from '@/components/ui/Fields';
import { Icon } from '@/components/ui/Icon';
import {
  addTag,
  MAX_TAG_LENGTH,
  MAX_TAGS_PER_TRANSACTION,
  newTagFor,
  removeTag,
  splitTyped,
  tagSuggestions,
  type Tag,
} from '@/domain/tags';
import type { TagInput } from '@/hooks/useTagInput';

import styles from './TagField.module.css';

/**
 * Tags on an expense or income: type one and press Enter (or comma), or tap an
 * existing tag. Existing tags are always offered — narrowed as you type — and
 * a name that does not exist yet is created when the transaction is saved.
 */
export function TagField({ input, known, disabled }: { input: TagInput; known: readonly Tag[]; disabled?: boolean }) {
  const { tags, setTags, draft, setDraft } = input;
  const full = tags.length >= MAX_TAGS_PER_TRANSACTION;
  const suggestions = full ? [] : tagSuggestions(known, tags, draft);
  const fresh = full ? null : newTagFor(known, tags, draft);

  const commit = (name: string) => {
    setTags((current) => addTag(current, name, known));
    setDraft('');
  };

  const onType = (text: string) => {
    if (!text.includes(',')) {
      setDraft(text);
      return;
    }
    const { done, rest } = splitTyped(text);
    setTags((current) => done.reduce((list, name) => addTag(list, name, known), current));
    setDraft(rest);
  };

  return (
    <div className={styles.root}>
      <TextField
        value={draft}
        onChange={onType}
        placeholder={full ? 'Tag limit reached' : 'Add tags'}
        aria-label="Tags"
        icon="tag"
        autoCapitalize="none"
        autoComplete="off"
        autoCorrect="off"
        maxLength={MAX_TAG_LENGTH}
        enterKeyHint="done"
        disabled={disabled || full}
        onKeyDown={(event) => {
          if (event.key === 'Enter') {
            // Adds the tag; never submits the form it sits in.
            event.preventDefault();
            if (draft.trim()) commit(draft);
          } else if (event.key === 'Backspace' && !draft && tags.length) {
            setTags((current) => current.slice(0, -1));
          }
        }}
      />
      {tags.length || fresh || suggestions.length ? (
        <div className={styles.chips} role="group" aria-label="Tags">
          {tags.map((name) => (
            <button
              key={name}
              type="button"
              className={styles.pill}
              disabled={disabled}
              onClick={() => setTags((current) => removeTag(current, name))}
              aria-label={`Remove tag ${name}`}
            >
              <span className={styles.label}>{name}</span>
              <Icon name="close" size={16} />
            </button>
          ))}
          {fresh ? <Chip label={fresh} icon="add" selected={false} disabled={disabled} onClick={() => commit(fresh)} /> : null}
          {suggestions.map((tag) => (
            <Chip key={tag.id} label={tag.name} icon="tag" selected={false} disabled={disabled} onClick={() => commit(tag.name)} />
          ))}
        </div>
      ) : null}
    </div>
  );
}
