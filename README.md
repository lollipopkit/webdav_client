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
await client.readDir('/');
```

### Create folder
```dart
await client.mkdir('/newFolder');
// Recursively
await client.mkdirAll('/new folder/new folder2');
```


### Remove
> If you remove the folder, some webdav services require a '/' at the end of the path.
```dart
// Delete folder
await client.remove('/new folder/new folder2/');

// Delete file
await client.remove('/new folder/text.txt');
```

### Rename
> If you rename the folder, some webdav services require a '/' at the end of the path.
```dart
await client.rename('/dir/', '/dir2/', overwrite: true);
await client.rename('/dir/test.dart', '/dir2/test2.dart', overwrite: true);
```

### Copy
- If copied a folder, it will copy all the contents.
- Some webdav services have been tested and found to delete the original contents of the target folder.
```dart
// Copy all the contents
await client.copy('/folder/folderA/', '/folder/folderB/', true);
// Copy file
await client.copy('/folder/aa.png', '/folder/bb.png', true);
```

### Download
```dart
// Bytes
await client.read('/folder/file', onProgress: (count, total) {
  print(count / total);
});

// Stream
await client.readFile(
  '/folder/file', 
  'file', 
  onProgress: (c, t) => print(c / t),
  cancelToken: CancelToken(),
);
```

### Upload
```dart
// upload local file 2 remote file with stream
await client.writeFile('file', '/f/file');
```

### Cancel request
```dart
final cancel = CancelToken();
client.mkdir('/dir', cancel)
.catchError((err) {
  prints(err.toString());
});
cancel.cancel('reason')
```
