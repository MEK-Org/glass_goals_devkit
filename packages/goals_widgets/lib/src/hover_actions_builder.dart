import 'package:flutter/widgets.dart' show Widget;
import 'package:goals_core/model.dart' show GoalPath;

typedef HoverActionsBuilder = Widget Function(GoalPath? goalId);
