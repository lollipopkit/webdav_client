import 'package:test/test.dart';
import 'package:webdav_client_plus/src/utils.dart';

void main() {
  group('Path join', () {
    test('basic', () {
      expect(joinPath('folder', 'file.txt'), equals('folder/file.txt'));
      expect(joinPath('parent', 'child'), equals('parent/child'));
      expect(joinPath('a/b', 'c/d'), equals('a/b/c/d'));
    });

    test('single slash', () {
      expect(joinPath('folder/', 'file.txt'), equals('folder/file.txt'));
      expect(joinPath('folder', '/file.txt'), equals('folder/file.txt'));
      expect(joinPath('folder/', '/file.txt'), equals('folder/file.txt'));
    });

    test('multi slashes', () {
      expect(joinPath('folder//', 'file.txt'), equals('folder/file.txt'));
      expect(joinPath('folder', '//file.txt'), equals('folder/file.txt'));
      expect(joinPath('folder///', '///file.txt'), equals('folder/file.txt'));
      expect(
          joinPath('a///b', '///c///d'), equals('a///b/c///d')); // 注意：只处理连接处的斜杠
    });

    test('empty', () {
      expect(joinPath('', 'file.txt'), equals('/file.txt'));
      expect(joinPath('folder', ''), equals('folder/'));
      expect(joinPath('', ''), equals('/'));
    });

    test('specials', () {
      expect(joinPath('/', '/'), equals('/'));
      expect(joinPath('/', 'file.txt'), equals('/file.txt'));
      expect(joinPath('/folder', '/'), equals('/folder/'));
      expect(joinPath('/remote.php/dav/files/admin', 'Documents'),
          equals('/remote.php/dav/files/admin/Documents'));
    });

    test('root', () {
      expect(joinPath('/', 'file.txt'), equals('/file.txt'));
      expect(joinPath('/', '/folder/file.txt'), equals('/folder/file.txt'));
    });

    test('same', () {
      expect(joinPath('/base/', '/path'), equals('/base/path'));
      expect(joinPath('/base', 'path/'), equals('/base/path/'));
      expect(joinPath('base/', '/path/'), equals('base/path/'));
    });
  });
}
