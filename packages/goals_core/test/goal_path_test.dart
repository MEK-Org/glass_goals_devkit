import 'package:goals_core/model.dart';
import 'package:test/test.dart';

void main() {
  test('GoalPath Equality', () async {
    final path1 = GoalPath([]);
    final path2 = GoalPath([]);

    expect(path1, equals(path2));
  });

  test('not equal', () async {
    final path1 = GoalPath(['abc']);
    final path2 = GoalPath([]);

    expect(path1, isNot(equals(path2)));
  });

  test('List Contains', () async {
    final pathList = [
      GoalPath(['abc']),
      GoalPath(['def'])
    ];
    expect(pathList.contains(GoalPath(['abc'])), isTrue);
  });

  test('ends with', () async {
    expect(GoalPath(['abc']).endsWith(GoalPath(['abc'])), isTrue);
    expect(GoalPath(['foo', 'abc']).endsWith(GoalPath(['abc'])), isTrue);
    expect(GoalPath(['abc']).endsWith(GoalPath(['foo', 'abc'])), isFalse);
    expect(GoalPath([]).endsWith(GoalPath([])), isTrue);
    expect(GoalPath(['abc']).endsWith(GoalPath([])), isTrue);
    expect(GoalPath(['xyz', 'abc', 'def']).endsWith(GoalPath(['abc', 'def'])),
        isTrue);
  });

  test('containsPath', () async {
    expect(GoalPath(['abc']).containsPath(GoalPath(['abc'])), isTrue);
    expect(GoalPath(['foo', 'abc']).containsPath(GoalPath(['abc'])), isTrue);
    expect(GoalPath(['abc']).containsPath(GoalPath(['foo', 'abc'])), isFalse);
    expect(GoalPath([]).containsPath(GoalPath([])), isTrue);
    expect(GoalPath(['abc']).containsPath(GoalPath([])), isTrue);
    expect(
        GoalPath(['xyz', 'abc', 'def']).containsPath(GoalPath(['abc', 'def'])),
        isTrue);
    expect(
        GoalPath(['xyz', 'abc', 'def', 'hij'])
            .containsPath(GoalPath(['abc', 'def'])),
        isTrue);
  });
}
