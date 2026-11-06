import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/features/files/unique_name.dart';

void main() {
  test('a free name is kept as is', () {
    expect(uniqueSiblingName('photo.jpg', ['other.jpg']), 'photo.jpg');
  });

  test('a taken name gets the first free counter before the extension', () {
    expect(
      uniqueSiblingName('photo.jpg', ['photo.jpg', 'photo (1).jpg']),
      'photo (2).jpg',
    );
  });

  test('names are compared case-insensitively', () {
    expect(uniqueSiblingName('Photo.JPG', ['photo.jpg']), 'Photo (1).JPG');
  });

  test('hidden files and names without an extension get a plain suffix', () {
    expect(uniqueSiblingName('.gitignore', ['.gitignore']), '.gitignore (1)');
    expect(uniqueSiblingName('README', ['README']), 'README (1)');
  });
}
