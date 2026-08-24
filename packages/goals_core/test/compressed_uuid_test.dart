import 'package:goals_core/util.dart' show Cupid;
import 'package:test/test.dart';

void main() {
  test('UUID round trip', () async {
    final uuid_4 = '00000000-0000-4000-8000-000000000000';
    final cupid_4 = Cupid(uuid_4);
    expect(cupid_4.toUuid(), equals(uuid_4));

    final uuid_5 = '00000000-0000-5000-8000-000000000000';
    final cupid_5 = Cupid(uuid_5);
    expect(cupid_5.toUuid(), equals(uuid_5));
  });

  test('detects invalid encoded value', () async {
    try {
      Cupid.decode('somerandomstring');
      fail('Expected exception not thrown');
    } catch (e) {
      // expected
    }
  });

  test('decode works', () async {
    expect(Cupid.decode("AAAAAAAAAIAAQA").toUuid(),
        equals('00000000-0000-4000-8000-000000000000'));
    expect(Cupid.decode('AAAAAAAAAIAAUA').toUuid(),
        equals('00000000-0000-5000-8000-000000000000'));
  });

  test('toNewId', () async {
    expect(Cupid.toNewId("00000000-0000-4000-8000-000000000000"),
        equals('AAAAAAAAAIAAQA'));
    expect(Cupid.toNewId('AAAAAAAAAIAAQA'), equals('AAAAAAAAAIAAQA'));
    expect(Cupid.toNewId('AAAAAAAAAIAAUA'), equals('AAAAAAAAAIAAUA'));
    expect(Cupid.toNewId('somerandomstring'),
        equals(Cupid.toNewId('somerandomstring')));
  });
}
