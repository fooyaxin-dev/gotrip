import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

enum WeatherCondition { clear, cloudy, rain, storm, extreme }

extension WeatherConditionX on WeatherCondition {
  String get label {
    switch (this) {
      case WeatherCondition.clear:   return 'Clear';
      case WeatherCondition.cloudy:  return 'Cloudy';
      case WeatherCondition.rain:    return 'Rain';
      case WeatherCondition.storm:   return 'Thunderstorm';
      case WeatherCondition.extreme: return 'Extreme';
    }
  }
}

/// Uses Open-Meteo (free, no API key needed, good Malaysia coverage).
/// Caches result for 20 min / ~3km so we don't spam calls on every
/// recommendation refresh.
class WeatherService {
  static final WeatherService instance = WeatherService._();
  WeatherService._();

  WeatherCondition? _cachedCondition;
  DateTime? _cachedAt;
  double? _cachedLat;
  double? _cachedLng;

  static const _cacheDuration       = Duration(minutes: 20);
  static const _cacheDistanceMeters = 3000.0;

  Future<WeatherCondition?> getCurrentCondition({
    required double lat,
    required double lng,
  }) async {
    if (_cachedCondition != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheDuration &&
        _cachedLat != null && _cachedLng != null &&
        _distanceMeters(lat, lng, _cachedLat!, _cachedLng!) < _cacheDistanceMeters) {
      print('🧠 WeatherService: cache hit (${_cachedCondition!.label})');
      return _cachedCondition;
    }

    try {
      final url = Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=$lat&longitude=$lng&current=weather_code,precipitation',
      );
      final response = await http.get(url);

      if (response.statusCode != 200) {
        print('❌ WeatherService: fetch failed ${response.statusCode}');
        return _cachedCondition; // fall back to stale value if we have one
      }

      final data = json.decode(response.body);
      final code = (data['current']?['weather_code'] as num?)?.toInt();
      final condition = _mapWeatherCode(code);

      _cachedCondition = condition;
      _cachedAt        = DateTime.now();
      _cachedLat       = lat;
      _cachedLng       = lng;

      print('🌦️ WeatherService: code=$code → ${condition?.label}');
      return condition;
    } catch (e) {
      print('❌ WeatherService exception: $e');
      return _cachedCondition;
    }
  }

  // WMO weather interpretation codes → simplified buckets
  WeatherCondition? _mapWeatherCode(int? code) {
    if (code == null) return null;
    if (code == 0 || code == 1) return WeatherCondition.clear;
    if (code == 2 || code == 3) return WeatherCondition.cloudy;
    if (code == 45 || code == 48) return WeatherCondition.cloudy; // fog
    const rainCodes = [51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82];
    if (rainCodes.contains(code)) return WeatherCondition.rain;
    if (code == 95 || code == 96 || code == 99) return WeatherCondition.storm;
    const snowCodes = [71, 73, 75, 77, 85, 86];
    if (snowCodes.contains(code)) return WeatherCondition.extreme;
    return WeatherCondition.cloudy;
  }

  double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLng = _deg2rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) * cos(_deg2rad(lat2)) *
        sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  double _deg2rad(double deg) => deg * (pi / 180.0);
}