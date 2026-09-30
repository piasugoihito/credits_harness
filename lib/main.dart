import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'notify/notifier.dart';
import 'ui/home.dart';
import 'ui/onboarding.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notifier.instance.init();
  final app = await AppState.load();
  runApp(App(app: app));
}

class App extends StatelessWidget {
  final AppState app;
  const App({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '単位ハーネス',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
      home: ListenableBuilder(
        listenable: app,
        builder: (context, _) => app.settings.setupDone ? HomePage(app: app) : OnboardingPage(app: app),
      ),
    );
  }
}
