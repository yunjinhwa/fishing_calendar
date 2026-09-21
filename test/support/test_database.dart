import 'package:fishing_build/data/local/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> resetTestDatabase() async {
  sqfliteFfiInit();
  await AppDatabase.instance.configureForTesting(
    databaseFactory: databaseFactoryFfiNoIsolate,
  );
}
