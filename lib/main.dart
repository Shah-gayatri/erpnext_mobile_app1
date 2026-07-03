import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Company HR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const AppGate(),
    );
  }
}

/// ---------------------------------------------------------------------
/// Native bridge: asks Android whether "Developer options" is enabled.
/// Backed by MainActivity.kt (MethodChannel "device_security").
/// ---------------------------------------------------------------------
class DeviceSecurity {
  static const _channel = MethodChannel('device_security');

  static Future<bool> isDeveloperModeOn() async {
    try {
      final bool result = await _channel.invokeMethod('isDeveloperModeOn');
      return result;
    } catch (e) {
      // If the check itself fails, decide fail-open vs fail-closed.
      // Fail-closed (block) is safer for your use case:
      return false;
    }
  }
}

/// ---------------------------------------------------------------------
/// Gate widget: shown first. Checks developer mode before letting the
/// user reach the actual HR WebView screen.
/// ---------------------------------------------------------------------
class AppGate extends StatefulWidget {
  const AppGate({super.key});

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  bool? _devModeOn;

  @override
  void initState() {
    super.initState();
    _checkDevMode();
  }

  Future<void> _checkDevMode() async {
    final result = await DeviceSecurity.isDeveloperModeOn();
    if (mounted) {
      setState(() => _devModeOn = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Still checking
    if (_devModeOn == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Developer options ON -> block the app
    if (_devModeOn == true) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.block, size: 64, color: Colors.red),
                SizedBox(height: 16),
                Text(
                  'This app cannot run while Developer Options is enabled.\n\n'
                  'Please disable Developer Options in your phone settings '
                  'and reopen the app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Developer options OFF -> proceed to the real app
    return const HrWebViewScreen();
  }
}

/// ---------------------------------------------------------------------
/// The actual HR WebView screen (unchanged logic, controller-init fixed).
/// ---------------------------------------------------------------------
class HrWebViewScreen extends StatefulWidget {
  const HrWebViewScreen({super.key});

  @override
  State<HrWebViewScreen> createState() => _HrWebViewScreenState();
}

class _HrWebViewScreenState extends State<HrWebViewScreen> {
  // Replace this with your actual ERPNext URL
  final String _hrPortalUrl = 'https://demo.itfarmer.in/';

  WebViewController? _controller; // nullable now: never touched before ready
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initPermissionsThenWebView();
  }

  // Step 1: ask Android (OS-level / Layer 1) for permissions up front,
  // then build the WebView once that's done.
  Future<void> _initPermissionsThenWebView() async {
    await [
      Permission.camera,
      Permission.microphone,
      Permission.location,
      Permission.photos, // Android 13+ media access
      Permission.storage, // Android 12 and below fallback
    ].request();

    _setupWebView();
  }

  void _setupWebView() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() {
              _isLoading = true;
            });
          },
          onPageFinished: (url) {
            setState(() {
              _isLoading = false;
            });
          },
        ),
      )
      ..loadRequest(Uri.parse(_hrPortalUrl));

    _controller = controller;
    _wireAndroidPermissionBridge(controller);

    // Force a rebuild now that _controller is ready, since initState itself
    // can't call setState directly.
    if (mounted) setState(() {});
  }

  // Step 2: wire the WebView's own permission bridge (Layer 2) — this is
  // what actually lets camera/mic/location/file-upload work for content
  // loaded INSIDE the WebView (e.g. a "scan receipt" or "GPS check-in"
  // feature on your ERPNext HR portal pages).
  void _wireAndroidPermissionBridge(WebViewController controller) {
    final androidController = controller.platform as AndroidWebViewController;

    // Camera / Microphone requests coming from JavaScript inside the page
    androidController.setOnPlatformPermissionRequest((request) async {
      final cameraStatus = await Permission.camera.status;
      final micStatus = await Permission.microphone.status;

      if (cameraStatus.isGranted || micStatus.isGranted) {
        await request.grant();
      } else {
        await request.deny();
      }
    });

    // Location requests (e.g. GPS check-in triggered from the HR portal page)
    androidController.setGeolocationPermissionsPromptCallbacks(
      onShowPrompt: (request) async {
        final locationStatus = await Permission.location.status;
        return GeolocationPermissionsResponse(
          allow: locationStatus.isGranted,
          retain: true,
        );
      },
    );

    // File upload fields (e.g. expense receipt upload, profile photo)
    androidController.setOnShowFileSelector((params) async {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: params.mode == FileSelectorMode.openMultiple,
        type: FileType.any,
      );
      if (result == null) return [];
      return result.files
          .where((f) => f.path != null)
          .map((f) => Uri.file(f.path!).toString())
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (controller == null) return;

        if (await controller.canGoBack()) {
          await controller.goBack();
        } else {
          if (mounted) {
            Navigator.of(context).maybePop();
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Company HR'),
        ),
        body: Stack(
          children: [
            // Only build the WebView once the controller actually exists.
            if (controller != null) WebViewWidget(controller: controller),
            if (_isLoading || controller == null)
              const Center(
                child: CircularProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }
}