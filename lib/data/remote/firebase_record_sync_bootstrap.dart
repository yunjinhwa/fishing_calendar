import 'package:firebase_core/firebase_core.dart';

import '../auth/auth_gateway.dart';
import 'firestore_record_sync_gateway.dart';
import 'record_sync_gateway.dart';

abstract final class FirebaseRecordSyncBootstrap {
  static RecordSyncGateway? create(AuthGateway? authGateway) {
    if (authGateway == null ||
        authGateway.availability != AuthGatewayAvailability.available ||
        Firebase.apps.isEmpty) {
      return null;
    }

    return FirestoreRecordSyncGateway();
  }
}
