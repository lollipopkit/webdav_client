import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

const _baseTestDir = '.test';
const _testDir = 'test dir';
const _testDir2 = 'test dir2';
const _testFile = 'README.md';
const _testFile2 = 'README2.md';

void main() {
  group('NoAuth', () {
    final client = WebdavClient.noAuth(url: 'http://localhost:5001');
    _testClient(client);

    test('Non-existent file', () async {
      expect(
        () => client.readFile('/non-existent-file.txt', 'output.txt'),
        throwsA(anything),
      );
    });
  });

  group('Basic', () {
    final client = WebdavClient(
        url: 'http://localhost:5002',
        auth: BasicAuth(user: 'test', pwd: 'test'));
    _testClient(client);
  });

  // group('Bearer', () {
  //   final client = WebdavClient(
  //       url: 'http://localhost:5001', auth: BearerAuth(token: 'test'));
  //   _testClient(client);
  // });

  // group('Digest', () {
  //   final client = WebdavClient(
  //     url: 'http://localhost:5001',
  //     auth: DigestAuth(
  //       user: 'test',
  //       pwd: 'test',
  //       digestParts: DigestParts(null),
  //     ),
  //   );
  //   _testClient(client);
  // });

  test('Invalid URL', () async {
    final invalidClient = WebdavClient.noAuth(url: 'http://invalid-url');
    expect(
      () => invalidClient.ping(),
      throwsA(anything),
    );
  });
}

void _testClient(WebdavClient client) async {
  test('init', () async {
    await Directory(_baseTestDir).delete(recursive: true);
    await Directory(_baseTestDir).create();

    // Settings

    client.setHeaders({'accept-charset': 'utf-8'});
    client.setConnectTimeout(8000);
    client.setSendTimeout(8000);
    client.setReceiveTimeout(8000);

    try {
      await client.ping();
    } catch (e) {
      print('$e');
    }
  });

  test('mkdir', () async {
    await client.mkdir(_testDir);
    await client.mkdirAll('/new folder/new folder2');
    await client.removeAll('/new folder');
  });

  test('write', () async {
    await client.writeFile(_testFile, '/$_testDir/$_testFile');
  });

  test('read', () async {
    final props = await client.readProps('/$_testDir/$_testFile');
    expect(props, isNotNull);
    expect(props?.size, isNotNull);
    expect(props?.modified, isNotNull);

    final notExists = await client.exists('/$_testDir/not-exists.txt');
    expect(notExists, isFalse);
  });

  test('list', () async {
    final listRootDir = await client.readDir('/');
    expect(listRootDir.length, 1);

    final listTestDir = await client.readDir(_testDir);
    expect(listTestDir.firstOrNull?.name, _testFile);
  });

  test('rename', () async {
    await client.rename(
      '/$_testDir/$_testFile',
      '/$_testDir2/$_testFile2',
      overwrite: true,
    );
    final renamed = await client.exists('/$_testDir2/$_testFile2');
    expect(renamed, isTrue);
  });

  test('read', () async {
    final readContent = await client.read('/$_testDir2/$_testFile2');
    expect(readContent, isNotEmpty);
  });

  test('copy', () async {
    await client.copy(
      '/$_testDir2/$_testFile2',
      '/$_testDir/$_testFile',
      overwrite: true,
    );
    final copied = await client.exists('/$_testDir/$_testFile');
    expect(copied, isTrue);
  });

  test('concurrent', () async {
    await Future.wait([
      client.mkdir('$_testDir/concurrent1'),
      client.mkdir('$_testDir/concurrent2'),
      client.mkdir('$_testDir/concurrent3'),
    ]);

    final dirs = await client.readDir('/$_testDir/');
    expect(dirs.where((d) => d.name.startsWith('concurrent')).length, 3);

    await Future.wait([
      client.remove('/$_testDir/concurrent1'),
      client.remove('/$_testDir/concurrent2'),
      client.remove('/$_testDir/concurrent3'),
    ]);
  });

  test('remove', () async {
    await client.remove('/$_testDir');
    await client.remove('/$_testDir2');
    final emptyDir = await client.readDir('/');
    expect(emptyDir, isEmpty);
  });
}
