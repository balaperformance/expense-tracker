/// One spacing, radius and sizing scale for the whole app.
///
/// Every gap in the UI comes from this file. The scale is deliberately tight:
/// a finance app is judged on how much it can show at a glance, and the
/// screens this replaced needed three scrolls to answer "what did I spend
/// this month?".
///
/// Density here is bought from padding, never from type size or touch
/// targets. Text sizes are unchanged from the readable scale in
/// [AppTypography], and every interactive element still clears
/// [minTouch] — buttons are drawn shorter than 48px and rely on Material's
/// padded tap target to reach it. The app looks tighter and hits the same.
class AppSpacing {
  const AppSpacing._();

  // ---------------------------------------------------------------------
  // Spacing scale
  // ---------------------------------------------------------------------

  /// Hairline separation — icon to its label, figure to its caption.
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;

  /// The workhorse. Padding inside compact rows and between related items.
  static const double md = 12;

  /// Standard card padding and the gap between cards.
  static const double lg = 14;
  static const double xl = 18;

  /// Between distinct sections.
  static const double xxl = 22;
  static const double xxxl = 28;

  /// Horizontal page gutter. Every screen body uses this so content lines up
  /// vertically as the user moves between tabs.
  static const double page = 14;

  /// Vertical gap between two sections of a scrolling page.
  ///
  /// A section header already carries its own bottom padding, so this is the
  /// gap *above* a header — the two together produce the visual separation,
  /// and doubling up here is what made the old screens so tall.
  static const double section = 14;

  /// Gap between sibling cards in a stack.
  static const double cardGap = 10;

  /// Padding inside a card. Tighter than the old 16 on every edge, which on
  /// a 360px phone was spending 9% of the width on nothing.
  static const double cardPad = 12;

  // ---------------------------------------------------------------------
  // Radii
  // ---------------------------------------------------------------------

  /// Chips, small tags, chart tooltips.
  static const double radiusXs = 8;
  static const double radiusSm = 10;

  /// Inputs.
  static const double radiusMd = 12;

  /// Buttons. One notch tighter than an input so a button reads as a solid
  /// object rather than as another field.
  static const double radiusButton = 11;

  /// Cards and sheets. Generous enough to read as a glass pane, restrained
  /// enough not to read as a toy.
  static const double radiusLg = 18;
  static const double radiusXl = 24;

  /// Sheets and the floating navigation bar — the largest panes in the app.
  static const double radiusXxl = 28;
  static const double radiusPill = 999;

  // ---------------------------------------------------------------------
  // Component sizing
  // ---------------------------------------------------------------------

  /// Hit-target floor. Buttons are drawn shorter than this and rely on
  /// Material's padded tap target to reach it, so density never costs
  /// reachability — the button looks 40px tall and is 48px tappable.
  static const double minTouch = 48;

  /// Standard button. Drawn at 40, tappable at 48.
  static const double buttonHeight = 40;

  /// Compact inline button — inside a card, beside a field, in an empty state.
  static const double buttonHeightSm = 32;

  /// The one committing action on a screen, pinned in a bar or sheet footer.
  /// The only button allowed to span the full width.
  static const double buttonHeightLg = 44;

  /// Extended FAB. Deliberately close to [buttonHeight]: a floating action
  /// should read as the same family as the buttons in the page, not as a
  /// different, larger species.
  static const double fabHeight = 42;

  /// Horizontal padding inside a button, by size.
  static const double buttonPadX = 15;
  static const double buttonPadXSm = 10;

  /// Gap between a button's icon and its label.
  static const double buttonIconGap = 6;

  /// Icon inside a button. Smaller than a standalone icon so it sits
  /// optically level with the label rather than towering over it.
  static const double buttonIcon = 17;
  static const double buttonIconSm = 15;

  /// Single-line input.
  static const double fieldHeight = 46;

  /// Vertical padding inside an input. The old 16 made every field 52px tall
  /// and a four-field form taller than the screen.
  static const double fieldPadY = 12;

  /// Leading avatar in a transaction or account row.
  static const double avatar = 34;
  static const double avatarSm = 30;

  /// Where a divider should start so it aligns with the text column rather
  /// than cutting under the avatar.
  static const double rowDividerIndent = avatar + md + md;

  /// Vertical padding inside a list row. With a 34px avatar this lands the
  /// row at 50px — one line of title, one of meta, and still over the touch
  /// floor without a ConstrainedBox having to stretch it.
  static const double rowPadY = 9;

  /// Icon sizes, so an app bar icon is never a different weight to a row icon.
  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double iconLg = 23;

  /// Height of the app bar. Shorter than Material's 56 — the title is the
  /// only thing in it and it sits on every screen.
  static const double appBarHeight = 50;

  /// Height of the floating glass navigation bar.
  static const double navBarHeight = 58;

  /// Space a scrolling tab must leave at the end of its content.
  ///
  /// The shell floats the navigation bar *over* the page rather than beside
  /// it, so these are no longer decorative breathing room — they are the only
  /// thing stopping the last row being permanently hidden behind the glass.
  ///
  /// The bar occupies [navBarHeight] plus its float and half the gesture
  /// inset, which is about 80 on a modern phone. The values below clear that
  /// and no more.
  static const double bottomListPadding = 100;

  /// For a tab with no floating action button, which needs to clear the bar
  /// but not the button above it.
  static const double bottomListPaddingNoFab = 86;

  /// For a pushed screen, which has its own floating action button and no
  /// navigation bar at all. Spending the tab-sized allowance here would leave
  /// 100px of nothing under every list the user drills into.
  static const double bottomListPaddingPage = 72;
}
