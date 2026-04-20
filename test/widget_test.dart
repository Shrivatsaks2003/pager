import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pager/screens/auth_screen.dart';

void main() {
  testWidgets('auth screen shows login controls', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const AuthScreen(),
      ),
    );

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Login'), findsWidgets);
    expect(find.text('Forgot password?'), findsOneWidget);
  });
}
