import 'package:geolocator/geolocator.dart';

class LocationService {
  LocationService._privateConstructor();
  static final LocationService instance = LocationService._privateConstructor();

  Position? currentPosition;

  double? get currentLat => currentPosition?.latitude;
  double? get currentLng => currentPosition?.longitude;

  Future<void> initLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    // 检查定位服务是否开启
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permissions are permanently denied');
    }

    // 获取当前位置
    currentPosition = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

    // 持续监听位置变化
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((Position pos) {
      currentPosition = pos;
    });
  }
}