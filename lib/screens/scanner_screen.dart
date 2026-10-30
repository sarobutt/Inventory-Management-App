import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Full-screen camera that returns a barcode (as a String), or null if the user goes back.
///
/// To avoid wrong reads it:
///  1. only looks at barcodes inside the white frame (the scan window), and
///  2. only accepts a number after reading the SAME value [_requiredMatches] times in a row.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  /// Number of identical consecutive reads needed before a barcode is accepted.
  static const int _requiredMatches = 3;

  /// A streak is forgotten if the next read arrives later than this (barcode left the frame).
  static const Duration _maxGap = Duration(milliseconds: 900);

  // `normal` reports every detection (unlike `noDuplicates`, which would hide repeat reads
  // that we need for confirmation). A short timeout keeps 3 reads well under a second.
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 120,
  );

  bool _done = false;
  bool _torch = false;
  String? _candidate;
  int _streak = 0;
  DateTime _lastRead = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;

    // Only barcodes inside the scan window reach here. If several are visible, the
    // value must still be identical across reads, so a stray code can't win.
    String? value;
    for (final b in capture.barcodes) {
      final v = b.rawValue?.trim();
      if (v != null && v.isNotEmpty) {
        value = v;
        break;
      }
    }
    if (value == null) return;

    final now = DateTime.now();
    if (value == _candidate && now.difference(_lastRead) <= _maxGap) {
      _streak++;
    } else {
      _candidate = value;
      _streak = 1;
    }
    _lastRead = now;

    if (_streak >= _requiredMatches) {
      _done = true;
      HapticFeedback.mediumImpact();
      SystemSound.play(SystemSoundType.click);
      Navigator.pop(context, value);
    } else if (mounted) {
      setState(() {}); // update the progress indicator
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan barcode'),
        actions: [
          IconButton(
            tooltip: 'Torch',
            icon: Icon(_torch ? Icons.flash_on : Icons.flash_off),
            onPressed: () async {
              await _controller.toggleTorch();
              if (mounted) setState(() => _torch = !_torch);
            },
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final boxWidth = constraints.maxWidth * 0.8;
          final boxHeight = boxWidth * 0.55;
          final window = Rect.fromCenter(
            center: Offset(constraints.maxWidth / 2, constraints.maxHeight / 2),
            width: boxWidth,
            height: boxHeight,
          );
          final reading = _streak > 0 && DateTime.now().difference(_lastRead) <= _maxGap;

          return Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(
                controller: _controller,
                scanWindow: window, // ignore barcodes outside the frame
                onDetect: _onDetect,
              ),
              // Dim everything outside the frame so it's clear where to aim.
              CustomPaint(painter: _MaskPainter(window)),
              Positioned.fromRect(
                rect: window,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: reading ? Colors.greenAccent : Colors.white, width: 3),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                top: window.bottom + 24,
                child: Column(
                  children: [
                    if (reading)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SizedBox(
                          width: 160,
                          child: LinearProgressIndicator(
                            value: _streak / _requiredMatches,
                            color: Colors.greenAccent,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                      ),
                    Text(
                      reading ? 'Hold steady…' : 'Fit the barcode inside the frame.\nIt scans automatically.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Darkens the camera view except for the scan window.
class _MaskPainter extends CustomPainter {
  final Rect window;
  _MaskPainter(this.window);

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()..addRect(Offset.zero & size);
    final hole = Path()..addRRect(RRect.fromRectAndRadius(window, const Radius.circular(16)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, outside, hole),
      Paint()..color = Colors.black54,
    );
  }

  @override
  bool shouldRepaint(_MaskPainter old) => old.window != window;
}
