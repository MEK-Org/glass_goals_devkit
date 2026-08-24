import 'dart:math' show Random;

String generateRandomString(int length) {
  const characters =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final random = Random();

  return List.generate(
      length, (index) => characters[random.nextInt(characters.length)]).join();
}
