import "package:flutter/material.dart" show ThemeExtension, Color, TextStyle;

class GoalsTheme extends ThemeExtension<GoalsTheme> {
  final double uiUnit;
  final Color primaryColor;
  final TextStyle focusedFontStyle;

  final Color activeGoalBg;
  final Color activeGoalFg;
  final Color doneGoalBg;
  final Color doneGoalFg;
  final Color archivedGoalBg;
  final Color archivedGoalFg;
  final Color pendingGoalBg;
  final Color pendingGoalFg;
  final Color toDoGoalBg;
  final Color toDoGoalFg;

  GoalsTheme({
    required this.uiUnit,
    required this.primaryColor,
    required this.focusedFontStyle,
    required this.activeGoalBg,
    required this.activeGoalFg,
    required this.doneGoalBg,
    required this.doneGoalFg,
    required this.archivedGoalBg,
    required this.archivedGoalFg,
    required this.pendingGoalBg,
    required this.pendingGoalFg,
    required this.toDoGoalBg,
    required this.toDoGoalFg,
  });

  @override
  ThemeExtension<GoalsTheme> copyWith({
    double? uiUnit,
    Color? primaryColor,
    TextStyle? focusedFontStyle,
    Color? activeGoalBg,
    Color? activeGoalFg,
    Color? doneGoalBg,
    Color? doneGoalFg,
    Color? archivedGoalBg,
    Color? archivedGoalFg,
    Color? pendingGoalBg,
    Color? pendingGoalFg,
    Color? toDoGoalBg,
    Color? toDoGoalFg,
  }) {
    return GoalsTheme(
      uiUnit: uiUnit ?? this.uiUnit,
      primaryColor: primaryColor ?? this.primaryColor,
      focusedFontStyle: focusedFontStyle ?? this.focusedFontStyle,
      activeGoalBg: activeGoalBg ?? this.activeGoalBg,
      activeGoalFg: activeGoalFg ?? this.activeGoalFg,
      doneGoalBg: doneGoalBg ?? this.doneGoalBg,
      doneGoalFg: doneGoalFg ?? this.doneGoalFg,
      archivedGoalBg: archivedGoalBg ?? this.archivedGoalBg,
      archivedGoalFg: archivedGoalFg ?? this.archivedGoalFg,
      pendingGoalBg: pendingGoalBg ?? this.pendingGoalBg,
      pendingGoalFg: pendingGoalFg ?? this.pendingGoalFg,
      toDoGoalBg: toDoGoalBg ?? this.toDoGoalBg,
      toDoGoalFg: toDoGoalFg ?? this.toDoGoalFg,
    );
  }

  @override
  ThemeExtension<GoalsTheme> lerp(
      covariant ThemeExtension<GoalsTheme>? other, double t) {
    if (other is! GoalsTheme) {
      return this;
    }
    return GoalsTheme(
      uiUnit: uiUnit + (other.uiUnit - uiUnit) * t,
      primaryColor: Color.lerp(primaryColor, other.primaryColor, t)!,
      focusedFontStyle:
          TextStyle.lerp(focusedFontStyle, other.focusedFontStyle, t)!,
      activeGoalBg: Color.lerp(activeGoalBg, other.activeGoalBg, t)!,
      activeGoalFg: Color.lerp(activeGoalFg, other.activeGoalFg, t)!,
      doneGoalBg: Color.lerp(doneGoalBg, other.doneGoalBg, t)!,
      doneGoalFg: Color.lerp(doneGoalFg, other.doneGoalFg, t)!,
      archivedGoalBg: Color.lerp(archivedGoalBg, other.archivedGoalBg, t)!,
      archivedGoalFg: Color.lerp(archivedGoalFg, other.archivedGoalFg, t)!,
      pendingGoalBg: Color.lerp(pendingGoalBg, other.pendingGoalBg, t)!,
      pendingGoalFg: Color.lerp(pendingGoalFg, other.pendingGoalFg, t)!,
      toDoGoalBg: Color.lerp(toDoGoalBg, other.toDoGoalBg, t)!,
      toDoGoalFg: Color.lerp(toDoGoalFg, other.toDoGoalFg, t)!,
    );
  }
}
