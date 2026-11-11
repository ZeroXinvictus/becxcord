import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/player_screen.dart';
import 'services/recorder_service.dart';
import 'theme.dart';

void main() {
  runApp(const BexxCordApp());
}

class BexxCordApp extends StatelessWidget {
  const BexxCordApp({super.key});

  @override
  Widget build(BuildContext context) {
    return RecorderHost(
      child: MaterialApp(
        title: 'BexxCord',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        initialRoute: '/',
        routes: {
          '/': const HomeScreen(),
          '/library': const LibraryScreen(),
        },
        onGenerateRoute: AppRoutes.onGenerateRoute,
      ),
    );
  }
}

class RecorderScope extends InheritedNotifier<RecorderController> {
  const RecorderScope({
    super.key,
    required RecorderController super.notifier,
    required super.child,
  });

  static RecorderController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RecorderScope>()!.notifier!;
}

class RecorderHost extends StatefulWidget {
  const RecorderHost({super.key, required this.child});

  final Widget child;

  @override
  State<RecorderHost> createState() => _RecorderHostState();
}

class _RecorderHostState extends State<RecorderHost> {
  final RecorderController _controller = RecorderController();

  @override
  void initState() {
    super.initState();
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RecorderScope(
      notifier: _controller,
      child: widget.child,
    );
  }
}

class AppRoutes {
  AppRoutes._();

  static Route<void>? onGenerateRoute(RouteSettings settings) {
    if (settings.name == '/player') {
      final entry = settings.arguments;
      if (entry is! RecordingEntry) return null;
      return MaterialPageRoute<void>(
        builder: (context) => PlayerScreen(entry: entry),
        settings: settings,
      );
    }
    return null;
  }
}
