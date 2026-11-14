// Pins the Dart SyncClient.getAllOpStrings contract that the TypeScript port
// (goals-core/src/sync-client.op-export.test.ts) must match: every op is
// exported as wire JSON, and each text log entry carries its exact body under
// d.lE.te, hydrated from the string store. Refs glass_goals_devkit#39.
import 'dart:convert';

import 'package:goals_core/sync.dart';
import 'package:test/test.dart';

const _noteBody =
    'Line one\n\n  indented "quoted" \\ back\tslash — “curly” é 🧪\r\nend';
const _docBody = '# Heading\n\n- item one\n- item two\n\nTrailing  spaces  ';

final _time = DateTime.fromMillisecondsSinceEpoch(1000);

Future<void> _settle(MemoryPersistenceService persistence) async {
  for (var i = 0; i < 4; i++) {
    await persistence.settled;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

Future<List<List<String>>> _exportChunks(SyncClient client) async {
  final chunks = <List<String>>[];
  await client.getAllOpStrings((chunk) async {
    // The Dart client reuses its buffer after the callback returns.
    chunks.add(List.of(chunk));
  });
  return chunks;
}

Map<String, dynamic>? _exportedEntry(List<String> strings, String entryId) {
  for (final s in strings) {
    final json = jsonDecode(s) as Map<String, dynamic>;
    final delta = json['d'] as Map<String, dynamic>?;
    final entry = delta?['lE'] as Map<String, dynamic>?;
    if (entry != null && entry['i'] == entryId) return entry;
  }
  return null;
}

void main() {
  group('SyncClient.getAllOpStrings exports text log entries (#39)', () {
    final kinds = <String, GoalLogEntry>{
      'note': NoteLogEntry(id: 'entry', creationTime: _time, text: _noteBody),
      'setSummary':
          SetSummaryEntry(id: 'entry', creationTime: _time, text: _noteBody),
      'parentContextComment': ParentContextCommentEntry(
          id: 'entry', creationTime: _time, parentId: 'p', text: _noteBody),
      'documentContents':
          DocumentContentsEntry(id: 'entry', creationTime: _time, text: _docBody),
    };

    kinds.forEach((kind, entry) {
      test('exports a $kind entry with its exact body', () async {
        final client = SyncClient();
        await client.init();
        await client.modifyGoal(GoalDelta(id: 'g', text: 'Goal'));
        await client.modifyGoal(GoalDelta(id: 'g', logEntry: entry));

        final strings = (await _exportChunks(client)).expand((c) => c).toList();

        expect(strings, hasLength(2));
        expect(_exportedEntry(strings, 'entry')?['te'],
            equals((entry as TextGoalLogEntry).text));
        client.dispose();
      });
    });

    test('hydrates bodies from the persisted string store after a restart',
        () async {
      final persistence = MemoryPersistenceService();
      final repo = MemorySyncRepository();
      final first = SyncClient(
          persistenceService: persistence,
          localStore: CachingLocalStore(repo: repo));
      await first.init();
      await first.modifyGoal(GoalDelta(id: 'g', text: 'Goal'));
      await first.modifyGoal(GoalDelta(
          id: 'g',
          logEntry:
              NoteLogEntry(id: 'n1', creationTime: _time, text: _noteBody)));
      await first.modifyGoal(GoalDelta(
          id: 'g',
          logEntry: DocumentContentsEntry(
              id: 'd1', creationTime: _time, text: _docBody)));
      await _settle(persistence);
      first.dispose();

      // A new store over the same repository starts with an empty cache.
      final cold = SyncClient(
          persistenceService: persistence,
          localStore: CachingLocalStore(repo: repo));
      await cold.init();
      await _settle(persistence);

      final strings = (await _exportChunks(cold)).expand((c) => c).toList();
      expect(strings, hasLength(3));
      expect(_exportedEntry(strings, 'n1')?['te'], equals(_noteBody));
      expect(_exportedEntry(strings, 'd1')?['te'], equals(_docBody));
      cold.dispose();
    });

    test('flushes full chunks of text entries and delivers the final chunk',
        () async {
      final client = SyncClient();
      await client.init();
      const noteCount = 1500;
      await client.modifyGoal(GoalDelta(id: 'g', text: 'Goal'));
      await client.modifyGoals([
        for (var i = 0; i < noteCount; i++)
          GoalDelta(
              id: 'g',
              logEntry: NoteLogEntry(
                  id: 'n$i', creationTime: _time, text: 'body $i\n')),
      ]);

      final chunks = await _exportChunks(client);

      expect(chunks.map((c) => c.length).toList(),
          equals([1000, noteCount + 1 - 1000]));
      final bodies = <String, dynamic>{};
      for (final s in chunks.expand((c) => c)) {
        final entry = (jsonDecode(s)['d'] as Map<String, dynamic>?)?['lE'];
        if (entry != null) bodies[entry['i'] as String] = entry['te'];
      }
      expect(bodies, hasLength(noteCount));
      for (var i = 0; i < noteCount; i++) {
        expect(bodies['n$i'], equals('body $i\n'));
      }
      client.dispose();
    });
  });
}
