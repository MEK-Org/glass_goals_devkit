extension StringComparison on String {
  /// Returns true if this string is alphabetically before the [other] string.
  ///
  /// This is a more readable equivalent of `this.compareTo(other) < 0`.
  ///
  /// Example:
  /// ```
  /// print('apple'.comesBefore('banana')); // true
  /// print('banana'.comesBefore('apple')); // false
  /// print('apple'.comesBefore('apple'));  // false
  /// ```
  bool comesBefore(String other) {
    return compareTo(other) < 0;
  }

  bool comesBeforeOrEquals(String other) {
    return compareTo(other) <= 0;
  }

  /// Returns true if this string is alphabetically after the [other] string.
  ///
  /// This is a more readable equivalent of `this.compareTo(other) > 0`.
  ///
  /// Example:
  /// ```
  /// print('banana'.comesAfter('apple')); // true
  /// print('apple'.comesAfter('banana')); // false
  /// print('apple'.comesAfter('apple'));  // false
  /// ```
  bool comesAfter(String other) {
    return compareTo(other) > 0;
  }

  bool comesAfterOrEquals(String other) {
    return compareTo(other) >= 0;
  }
}
