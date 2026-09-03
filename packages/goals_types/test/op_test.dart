import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:goals_types/goals_types.dart'
    show
        CourseMetadataLogEntry,
        ReadingAssignmentLogEntry,

        DeltaOp,
        DisableOp,
        EnableOp,
        GoalDelta,
        GoalStatus,
        Op,
        StatusLogEntry;
import 'package:json_schema/json_schema.dart';

void main() {
  late JsonSchema opSchema;

  setUpAll(() async {
    final schemaText = await File('lib/src/op_schema.json').readAsString();
    opSchema = await JsonSchema.createAsync(jsonDecode(schemaText));
  });

  Future<void> expectValidOpJson(dynamic jsonObj, {String? ref}) async {
    if (ref == null) {
      final valid = opSchema.validate(jsonObj);
      expect(valid, isTrue, reason: 'JSON does not match op_schema.json');
    } else {
      final schemaText = await File('lib/src/op_schema.json').readAsString();
      final rootSchema = await JsonSchema.createAsync(jsonDecode(schemaText));
      final typeSchema = rootSchema.definitions[ref];

      if (typeSchema == null) {
        throw Exception('Schema for $ref not found in op_schema.json');
      }
      final result = typeSchema.validate(jsonObj);
      expect(result.isValid, isTrue,
          reason: 'JSON does not match $ref in op_schema.json');
    }
  }

  test('op to json works', () async {
    final op = DeltaOp(
      hlcTimestamp: '0',
      id: '0',
      delta: GoalDelta(
          id: '1',
          text: 'foo',
          logEntry: StatusLogEntry(
              id: '2',
              creationTime: DateTime.utc(2023),
              status: GoalStatus.active)),
    );

    final jsonStr = op.toJson();
    final jsonObj = jsonDecode(jsonStr);
    await expectValidOpJson(jsonObj, ref: 'WireDeltaOp');

    expect(
        jsonStr,
        equals(
            '{"h":"0","i":"0","v":6,"t":"d","d":{"i":"1","t":"foo","lE":{"i":"2","cT":1672531200000,"t":"s","s":"a"}}}'));

    final op2 = Op.fromJson(jsonStr);
    expect(op2, equals(op));
  });

  test('op json round trip works, deltaOp', () {
    final op = DeltaOp(
      hlcTimestamp: '0',
      id: '0',
      delta: GoalDelta(
          id: '1',
          text: 'foo',
          logEntry: StatusLogEntry(
              id: '2',
              creationTime: DateTime.utc(2023),
              status: GoalStatus.active)),
    );
    final jsonStr = op.toJson();
    final jsonObj = jsonDecode(jsonStr);
    expectValidOpJson(jsonObj, ref: 'WireDeltaOp');
    final op2 = Op.fromJson(jsonStr);
    expect(op2, equals(op));
  });

  test('op json round trip works, enableOp', () {
    final op = EnableOp(
      hlcTimestamp: '0',
      id: '0',
      opId: '1',
    );
    final jsonStr = op.toJson();
    final jsonObj = jsonDecode(jsonStr);
    expectValidOpJson(jsonObj, ref: 'WireEnableOp');
    final op2 = Op.fromJson(jsonStr);
    expect(op2, equals(op));
  });

  test('op json round trip works, disableOp', () {
    final op = DisableOp(
      hlcTimestamp: '0',
      id: '0',
      opId: '1',
    );
    final jsonStr = op.toJson();
    final jsonObj = jsonDecode(jsonStr);
    expectValidOpJson(jsonObj, ref: 'WireDisableOp');
    final op2 = Op.fromJson(jsonStr);
    expect(op2, equals(op));
  });

  test('WireCourseMetadataLogEntry validation', () async {
    final entry = CourseMetadataLogEntry(
      id: '1',
      creationTime: DateTime.utc(2023),
      textbookGoalIds: ['textbook1'],
    );
    final jsonObj = jsonDecode(jsonEncode(entry.toJsonMap()));
    await expectValidOpJson(jsonObj, ref: 'WireCourseMetadataLogEntry');
  });

  test('WireReadingAssignmentLogEntry validation', () async {
    final entry = ReadingAssignmentLogEntry(
      id: '2',
      creationTime: DateTime.utc(2023),
      textbookGoalId: 'textbook1',
      startPage: 1,
      endPage: 10,
    );
    final jsonObj = jsonDecode(jsonEncode(entry.toJsonMap()));
    await expectValidOpJson(jsonObj, ref: 'WireReadingAssignmentLogEntry');
  });

  test('WireClassMapping validation', () async {
    final jsonObj = {
      'cN': 1,
      'gI': 'goal1',
      'tp': 'Topic 1'
    };
    await expectValidOpJson(jsonObj, ref: 'WireClassMapping');
  });

  test('WireSyllabusParseResultLogEntry validation', () async {
    final jsonObj = {
      'i': '3',
      'cT': 12345,
      't': 'sPR',
      'cfGI': 'folder1',
      'tGI': 'textbook1',
      'cM': [
        {
          'cN': 1,
          'gI': 'goal1',
          'tp': 'Topic 1'
        }
      ],
      'aF': 'file.pdf'
    };
    await expectValidOpJson(jsonObj, ref: 'WireSyllabusParseResultLogEntry');
  });

  test('ops.ts has no digit-suffixed exports', () async {
    final file = File('../goals-types/src/ops.ts');
    final contents = await file.readAsString();
    final exportMatches = RegExp(r'export (?:interface|type) ([A-Za-z0-9_]+)').allMatches(contents);
    for (final match in exportMatches) {
      final name = match.group(1)!;
      expect(RegExp(r'\d$').hasMatch(name), isFalse, reason: 'Export $name ends in a digit');
    }
  });
}
