# webdav_client_plus

## Usage

```dart
final client = WebdavClient.noAuth('http://localhost:6688/');
```

### Common settings
```dart
// Set the public request headers
client.setHeaders({'accept-charset': 'utf-8'});
// Set the connection server timeout time in milliseconds.
client.setConnectTimeout(8000);
// Set send data timeout time in milliseconds.
client.setSendTimeout(8000);
// Set transfer data time in milliseconds.
client.setReceiveTimeout(8000);
// Test whether the service can connect
try {
  await client.ping();
} catch (e) {
  print('$e');
}
```

### Read all files in a folder
```dart
var list = await client.readDir('/');
list.forEach((f) {
  print('${f.name} ${f.path}');
});
```

### Create folder
```dart
await client.mkdir('/newFolder');
// Recursively create folders
await client.mkdirAll('/new folder/new folder2');
```

### Remove a folder or file
> If you remove the folder, some webdav services require a '/' at the end of the path.
```dart
// Delete folder
await client.remove('/new folder/new folder2/');

// Delete file
await client.remove('/new folder/text.txt');
```

### Rename a folder or file
> If you rename the folder, some webdav services require a '/' at the end of the path.
```dart
// Rename folder
await client.rename('/dir/', '/dir2/', overwrite: true);

// Rename file
await client.rename('/dir/test.dart', '/dir2/test2.dart', overwrite: true);
```

### Copy a file / folder from A to B
> If copied the folder (A > B), it will copy all the contents of folder A to folder B.

> Some webdav services have been tested and found to delete the original contents of the B folder!!!
```dart
// Copy all the contents of folderA to folder B
await client.copy('/folder/folderA/', '/folder/folderB/', true);

// Copy file
await client.copy('/folder/aa.png', '/folder/bb.png', true);
```

### Download file
```dart
// Bytes
await client.read('/folder/file', onProgress: (count, total) {
  print(count / total);
});

// Stream
await client.read2File(
  '/folder/file', 
  'file', 
  onProgress: (c, t) => print(c / t),
  cancelToken: CancelToken(),
);
```

### Upload file
```dart
// upload local file 2 remote file with stream
await client.writeFile('file', '/f/file');
```

### Cancel request
```dart
final cancel = CancelToken();

// Supports most methods
client.mkdir('/新建文件夹', cancel)
.catchError((err) {
  prints(err.toString());
});

// Cancel request
cancel.cancel('reason')
```
