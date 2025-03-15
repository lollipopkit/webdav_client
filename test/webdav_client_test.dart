import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:webdav_client/src/client.dart';
import 'package:webdav_client/webdav_client.dart';

const _testDir = 'test dir';
const _testDir2 = 'test dir2';
const _testFile = 'README.md';
const _testFile2 = 'README2.md';

void main() {
  final client = WebdavClient(
    url: 'http://localhost:5001',
    user: '',
    pwd: '',
  );

  // test ping
  test('settings', () async {
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
    CancelToken c = CancelToken();
    await client.writeFile(
      _testFile,
      '/$_testDir/$_testFile',
      onProgress: (c, t) => print(c / t),
      cancelToken: c,
    );
  });

  test('list', () async {
    for (final f in await client.readDir('/')) {
      print('${f.name} ${f.path}');
    }

    final list = await client.readDir(_testDir);
    for (final f in list) {
      print('${f.name} ${f.path}');
    }
  });

  test('rename', () async {
    await client.rename(
      '/$_testDir/$_testFile',
      '/$_testDir2/$_testFile2',
      overwrite: true,
    );
  });

  test('read', () async {
    await client.readFile(
      '/$_testDir2/$_testFile2',
      '$_testFile',
      onProgress: (c, t) => print(c / t),
    );
  });

  test('rm', () async {
    await client.remove('/$_testDir2/$_testFile2');
    await client.remove('/$_testDir2/');
  });
}
