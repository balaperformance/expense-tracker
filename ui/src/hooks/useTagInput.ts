import { useState, type Dispatch, type SetStateAction } from 'react';

/**
 * The tags being edited on a form: the ones chosen so far and the text still
 * being typed. The typed text is kept here (not inside the field) so saving
 * can include a tag the user typed but did not confirm with Enter.
 */
export type TagInput = {
  tags: string[];
  setTags: Dispatch<SetStateAction<string[]>>;
  draft: string;
  setDraft: Dispatch<SetStateAction<string>>;
};

export function useTagInput(initial: readonly string[] = []): TagInput {
  const [tags, setTags] = useState<string[]>(() => [...initial]);
  const [draft, setDraft] = useState('');
  return { tags, setTags, draft, setDraft };
}
