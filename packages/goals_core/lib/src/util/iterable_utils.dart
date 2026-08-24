// Extension on Iterable to partition elements by a predicate.
extension PartitionExtension<T> on Iterable<T> {
  /// Splits the iterable into two lists: [matching, nonMatching].
  /// The first contains elements where [test] returns true, the second where it returns false.
  (List<T>, List<T>) partition(bool Function(T) test) {
    final matching = <T>[];
    final nonMatching = <T>[];
    for (final element in this) {
      if (test(element)) {
        matching.add(element);
      } else {
        nonMatching.add(element);
      }
    }
    return (matching, nonMatching);
  }
}
