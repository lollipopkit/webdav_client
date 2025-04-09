import 'dart:typed_data';

import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() async {
  // Create client with BasicAuth
  final client = WebdavClient(
    url: 'https://example.com/webdav',
    auth: const BasicAuth(
      user: 'username',
      pwd: 'password',
    ),
  );

  try {
    // List files in the root directory
    final files = await client.readDir('/');
    print('Files in root directory:');
    for (final file in files) {
      print('- ${file.name} (${file.isDir ? "Directory" : "File"})');
    }

    // Upload a file
    const content = 'Hello WebDAV with BasicAuth!';
    await client.write(
        '/test_basic.txt', Uint8List.fromList(content.codeUnits));
    print('File uploaded successfully');

    // Download a file
    final downloadedContent = await client.read('/test_basic.txt');
    print('Downloaded content: $downloadedContent');
  } catch (e) {
    print('Error: $e');
  }
}
