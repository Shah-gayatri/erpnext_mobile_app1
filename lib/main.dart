import 'dart:async';
import 'dart:convert';

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
      title: 'SkyErp',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        brightness: Brightness.light,
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 1,
        ),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          foregroundColor: Colors.white,
          elevation: 1,
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _goNext();
  }

  Future<void> _goNext() async {
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const AppGate()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Image.asset(
          'assets/splash/logo_icon_square.png',
          width: 250,
        ),
      ),
    );
  }
}

class DeviceSecurity {
  static const _channel = MethodChannel('device_security');

  static Future<bool> isDeveloperModeOn() async {
    try {
      return await _channel.invokeMethod('isDeveloperModeOn');
    } catch (e) {
      return false;
    }
  }

  static Future<bool> isVpnActive() async {
    try {
      return await _channel.invokeMethod('isVpnActive');
    } catch (e) {
      return false;
    }
  }

  static Future<bool> isMockLocationOn() async {
    try {
      return await _channel.invokeMethod('isMockLocationOn');
    } catch (e) {
      return false;
    }
  }

  static Future<String> getAndroidId() async {
    try {
      final id = await _channel.invokeMethod('getAndroidId');
      return (id as String?) ?? '';
    } catch (e) {
      return '';
    }
  }
}

class AppGate extends StatefulWidget {
  const AppGate({super.key});

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  bool? _blocked;
  String _reason = '';

  @override
  void initState() {
    super.initState();
    _runChecks();
  }

  Future<void> _runChecks() async {
    final devMode = await DeviceSecurity.isDeveloperModeOn();
    if (devMode) {
      if (mounted) {
        setState(() {
          _blocked = true;
          _reason = 'Developer Options is enabled on this device.';
        });
      }
      return;
    }

    final vpnOn = await DeviceSecurity.isVpnActive();
    if (vpnOn) {
      if (mounted) {
        setState(() {
          _blocked = true;
          _reason = 'A VPN connection is active on this device.';
        });
      }
      return;
    }

    final mockLocation = await DeviceSecurity.isMockLocationOn();
    if (mockLocation) {
      if (mounted) {
        setState(() {
          _blocked = true;
          _reason = 'Fake/Mock GPS location was detected on this device.';
        });
      }
      return;
    }

    if (mounted) {
      setState(() => _blocked = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_blocked == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_blocked == true) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.block, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  'This app cannot run right now.\n\n$_reason\n\n'
                  'Please disable it and reopen the app.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return const HrWebViewScreen();
  }
}

class HrWebViewScreen extends StatefulWidget {
  const HrWebViewScreen({super.key});

  @override
  State<HrWebViewScreen> createState() => _HrWebViewScreenState();
}

class _HrWebViewScreenState extends State<HrWebViewScreen> {
  static const String _baseUrl =
      'https://demo.itfarmer.in/';

  WebViewController? _controller;
  bool _isLoading = true;
  String _deviceId = '';

  // --- ERPNext theme sync state ---
  Color _headerBg = Colors.white;
  Color _headerFg = Colors.black;
  Timer? _themePollTimer;

  // JS injected into the page to read ERPNext's active theme.
  // Tries the CSS custom properties Frappe sets on <body>/<html> first
  // (these track "Frappe Light" / "Timeless Night" / "Automatic" / any
  // custom theme automatically), then falls back to the localStorage key.
  static const String _themeProbeJs = r"""
(() => {
  try {
    const rootStyle = getComputedStyle(document.documentElement);
    const bodyStyle = getComputedStyle(document.body);

    const pick = (name) => {
      let v = rootStyle.getPropertyValue(name).trim();
      if (!v) v = bodyStyle.getPropertyValue(name).trim();
      return v;
    };

    // Frappe/ERPNext desk CSS variables (fall back through a few known names
    // since these vary slightly by version).
    const bg = pick('--navbar-bg') || pick('--fg-color') || pick('--bg-color') || pick('--card-bg');
    const fg = pick('--text-color') || pick('--gray-900') || pick('--text-on-gray');

    const storedTheme = localStorage.getItem('preferred_theme')
      || localStorage.getItem('theme')
      || '';

    return JSON.stringify({ bg: bg, fg: fg, storedTheme: storedTheme });
  } catch (e) {
    return JSON.stringify({ bg: '', fg: '', storedTheme: '', error: String(e) });
  }
})();
""";

  @override
  void initState() {
    super.initState();
    _initDeviceIdThenPermissionsThenWebView();
  }

  @override
  void dispose() {
    _themePollTimer?.cancel();
    super.dispose();
  }

  Future<void> _initDeviceIdThenPermissionsThenWebView() async {
    _deviceId = await DeviceSecurity.getAndroidId();
    await _initPermissionsThenWebView();
  }

  Future<void> _initPermissionsThenWebView() async {
    await [
      Permission.camera,
      Permission.microphone,
      Permission.location,
      Permission.photos,
      Permission.storage,
    ].request();

    _setupWebView();
  }

  String get _hrPortalUrl {
    if (_deviceId.isEmpty) return _baseUrl;
    final uri = Uri.parse(_baseUrl);
    final newUri = uri.replace(queryParameters: {
      ...uri.queryParameters,
      'deviceid': _deviceId,
    });
    return newUri.toString();
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
          onPageFinished: (url) async {
            setState(() {
              _isLoading = false;
            });

            if (_deviceId.isNotEmpty) {
              try {
                await _controller?.runJavaScript(
                  "localStorage.setItem('erpnext_device_id', '$_deviceId');",
                );
              } catch (_) {
                // Non-fatal — page may not have finished attaching JS bridge yet
              }
            }

            // Do an immediate theme read, then start polling so we also
            // catch in-page theme switches (ERPNext's theme toggle doesn't
            // reload the page — it just flips CSS variables/attributes).
            await _syncErpTheme();
            _themePollTimer?.cancel();
            _themePollTimer = Timer.periodic(
              const Duration(seconds: 2),
              (_) => _syncErpTheme(),
            );
          },
        ),
      )
      ..loadRequest(Uri.parse(_hrPortalUrl));

    _controller = controller;
    _wireAndroidPermissionBridge(controller);

    if (mounted) setState(() {});
  }

  Future<void> _syncErpTheme() async {
    final controller = _controller;
    if (controller == null) return;

    try {
      final raw = await controller.runJavaScriptReturningResult(_themeProbeJs);
      // runJavaScriptReturningResult on Android returns a JSON-encoded
      // string (i.e. the whole thing is double-quoted and escaped), so
      // decode it once to get the actual JSON string, then parse that.
      String jsonStr = raw.toString();
      try {
        jsonStr = jsonDecode(jsonStr) as String;
      } catch (_) {
        // Some platforms return the raw string already unescaped — ignore.
      }

      final Map<String, dynamic> data = jsonDecode(jsonStr);
      final String bgRaw = (data['bg'] ?? '').toString();
      final String fgRaw = (data['fg'] ?? '').toString();
      final String storedTheme = (data['storedTheme'] ?? '').toString();

      Color? bg = _parseCssColor(bgRaw);
      Color? fg = _parseCssColor(fgRaw);

      // Fallback: if CSS variables weren't readable, use the stored theme
      // name to guess light vs dark.
      if (bg == null || fg == null) {
        final isDark = storedTheme.toLowerCase().contains('night') ||
            storedTheme.toLowerCase().contains('dark');
        bg ??= isDark ? const Color(0xFF1E1E1E) : Colors.white;
        fg ??= isDark ? Colors.white : Colors.black;
      }

      if (!mounted) return;
      if (bg != _headerBg || fg != _headerFg) {
        setState(() {
          _headerBg = bg!;
          _headerFg = fg!;
        });
      }
    } catch (_) {
      // Non-fatal — keep whatever header color we currently have.
    }
  }

  // Parses common CSS color formats: rgb(), rgba(), and #hex.
  Color? _parseCssColor(String value) {
    final v = value.trim();
    if (v.isEmpty) return null;

    final rgbMatch =
        RegExp(r'rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)').firstMatch(v);
    if (rgbMatch != null) {
      final r = double.tryParse(rgbMatch.group(1) ?? '')?.round() ?? 0;
      final g = double.tryParse(rgbMatch.group(2) ?? '')?.round() ?? 0;
      final b = double.tryParse(rgbMatch.group(3) ?? '')?.round() ?? 0;
      return Color.fromARGB(255, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
    }

    if (v.startsWith('#')) {
      var hex = v.substring(1);
      if (hex.length == 3) {
        hex = hex.split('').map((c) => '$c$c').join();
      }
      if (hex.length == 6) hex = 'FF$hex';
      final parsed = int.tryParse(hex, radix: 16);
      if (parsed != null) return Color(parsed);
    }

    return null;
  }

  void _wireAndroidPermissionBridge(WebViewController controller) {
    final androidController = controller.platform as AndroidWebViewController;

    androidController.setOnPlatformPermissionRequest((request) async {
      final cameraStatus = await Permission.camera.status;
      final micStatus = await Permission.microphone.status;

      if (cameraStatus.isGranted || micStatus.isGranted) {
        await request.grant();
      } else {
        await request.deny();
      }
    });

    androidController.setGeolocationPermissionsPromptCallbacks(
      onShowPrompt: (request) async {
        final locationStatus = await Permission.location.status;
        return GeolocationPermissionsResponse(
          allow: locationStatus.isGranted,
          retain: true,
        );
      },
    );

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
          backgroundColor: _headerBg,
          foregroundColor: _headerFg,
          title: const Text('SkyErp'),
        ),
        body: Stack(
          children: [
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