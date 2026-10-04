import 'package:flutter/material.dart';
import 'package:goals_core/model.dart';
import 'package:goals_core/sync.dart';
import 'package:goals_ui_core/core.dart';
import 'package:goals_widgets/src/goal_breadcrumb.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final client = SyncClient(
    localStore: MemoryLocalStore(),
    persistenceService: MemoryPersistenceService(),
  );
  await client.init();
  runApp(
    MaterialApp(
      home: GoalWidgetsContext(
        syncClient: client,
        child: GoalActionsContext.empty(
          child: ParentBreadcrumb(path: GoalPath(['root'])),
        ),
      ),
    ),
  );
}
