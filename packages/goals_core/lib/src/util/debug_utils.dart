import 'package:goals_core/model.dart' show Goal;

void debugPrintPath(Map<String, Goal> goalMap, List<String> path) {
  print(getDebugString(goalMap, path));
}

String getDebugString(Map<String, Goal> goalMap, List<String> path) {
  final goalTexts = path.map((goalId) => goalMap[goalId]!.text).toList();
  return goalTexts.join(' > ');
}
