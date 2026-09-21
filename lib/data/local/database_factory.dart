import 'package:sqflite/sqflite.dart';

import 'database_factory_stub.dart'
    if (dart.library.io) 'database_factory_io.dart'
    as platform;

DatabaseFactory createLocalDatabaseFactory() {
  return platform.createLocalDatabaseFactory();
}
