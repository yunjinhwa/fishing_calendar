import '../models/external_data.dart';

class MockExternalDataService {
  Future<ExternalData> fetchCurrentData({
    required String locationName,
  }) async {
    await Future.delayed(const Duration(milliseconds: 700));

    if (locationName.contains('실패')) {
      throw Exception('mock external data failure');
    }

    return ExternalData(
      locationName: locationName,
      weather: '흐림',
      airTemperature: 18,
      tide: '7물',
      waterTemperature: 16.2,
      observationPointName: '$locationName 인근 관측소',
      observedAt: DateTime.now(),
    );
  }
}