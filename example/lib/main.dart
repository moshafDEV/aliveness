import 'package:aliveness/aliveness.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Aliveness Example',
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Uint8List>? _result;
  bool _isLoading = false;

  Future<void> _startLiveness() async {
    setState(() => _isLoading = true);

    final result = await Aliveness().start(
      context: context,
      expressions: [
        ChallengeExpression.smile,
        ChallengeExpression.eyeblink,
        ChallengeExpression.leftPose,
        ChallengeExpression.rightPose,
        ChallengeExpression.nodUp,
        ChallengeExpression.nodDown,
        ChallengeExpression.tiltLeft,
        ChallengeExpression.tiltRight,
        ChallengeExpression.openMouth,
        ChallengeExpression.winkLeft,
        ChallengeExpression.winkRight,
      ],
    );

    if (!mounted) return;
    setState(() {
      if (result != null && result.photos.isNotEmpty) {
        _result = result.photos.map((photo) {
          List<int> imageBytes = img.encodeJpg(photo);
          return Uint8List.fromList(imageBytes);
        }).toList();
      }
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Aliveness Example')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_result != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  spacing: 12,
                  children: _result!.map((photo) {
                    return Image.memory(photo, width: 120, height: 120, fit: BoxFit.cover);
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isLoading ? null : _startLiveness,
              child: _isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Start Liveness Detection'),
            ),
          ],
        ),
      ),
    );
  }
}
