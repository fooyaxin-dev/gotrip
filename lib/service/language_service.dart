import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

class LanguageService extends ChangeNotifier {
  static LanguageService instance = LanguageService._();

  LanguageService._();

  Map<String, dynamic> _localizedStrings = {};
  String _currentLang = 'en';

  String get currentLang => _currentLang;

  Future<void> load(String languageCode) async {
    _currentLang = languageCode;
    final jsonString =
        await rootBundle.loadString('assets/lang/$languageCode.json');
    _localizedStrings = json.decode(jsonString);
    notifyListeners(); // 通知 UI 更新
  }

  String text(String key) {
    return _localizedStrings[key] ?? '**$key**';
  }
}
