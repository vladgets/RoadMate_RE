import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<void> shareCollageBytes(List<int> pngBytes) async {
  final tempDir = await getTemporaryDirectory();
  final file = File('${tempDir.path}/collage_${DateTime.now().millisecondsSinceEpoch}.png');
  await file.writeAsBytes(pngBytes);

  await Share.shareXFiles(
    [XFile(file.path)],
    text: 'Check out my photo collage!',
  );

  Future.delayed(const Duration(seconds: 5), () {
    if (file.existsSync()) file.delete();
  });
}
