import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
///
/// Example:
/// ```dart
/// import 'firebase_options.dart';
/// // ...
/// await Firebase.initializeApp(
///   options: DefaultFirebaseOptions.currentPlatform,
/// );
/// ```
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        return linux;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBSdBCpZ9-WyKI8y9qxjPOsl3WFTP3TO7Y',
    appId: '1:942715338146:web:7460ee39eb03b66e8f46fb',
    messagingSenderId: '942715338146',
    projectId: 'authentication-b408d',
    authDomain: 'authentication-b408d.firebaseapp.com',
    storageBucket: 'authentication-b408d.firebasestorage.app',
    measurementId: 'G-XXXXXXXXXX',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBSdBCpZ9-WyKI8y9qxjPOsl3WFTP3TO7Y',
    appId: '1:942715338146:android:7460ee39eb03b66e8f46fb',
    messagingSenderId: '942715338146',
    projectId: 'authentication-b408d',
    storageBucket: 'authentication-b408d.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBSdBCpZ9-WyKI8y9qxjPOsl3WFTP3TO7Y',
    appId: '1:942715338146:ios:7460ee39eb03b66e8f46fb',
    messagingSenderId: '942715338146',
    projectId: 'authentication-b408d',
    storageBucket: 'authentication-b408d.firebasestorage.app',
    iosBundleId: 'com.example.bleBeaconTracker',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyBSdBCpZ9-WyKI8y9qxjPOsl3WFTP3TO7Y',
    appId: '1:942715338146:ios:7460ee39eb03b66e8f46fb',
    messagingSenderId: '942715338146',
    projectId: 'authentication-b408d',
    storageBucket: 'authentication-b408d.firebasestorage.app',
    iosBundleId: 'com.example.bleBeaconTracker',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyBSdBCpZ9-WyKI8y9qxjPOsl3WFTP3TO7Y',
    appId: '1:942715338146:web:7460ee39eb03b66e8f46fb',
    messagingSenderId: '942715338146',
    projectId: 'authentication-b408d',
    authDomain: 'authentication-b408d.firebaseapp.com',
    storageBucket: 'authentication-b408d.firebasestorage.app',
    measurementId: 'G-XXXXXXXXXX',
  );

  static const FirebaseOptions linux = FirebaseOptions(
    apiKey: 'AIzaSyBSdBCpZ9-WyKI8y9qxjPOsl3WFTP3TO7Y',
    appId: '1:942715338146:web:7460ee39eb03b66e8f46fb',
    messagingSenderId: '942715338146',
    projectId: 'authentication-b408d',
    authDomain: 'authentication-b408d.firebaseapp.com',
    storageBucket: 'authentication-b408d.firebasestorage.app',
    measurementId: 'G-XXXXXXXXXX',
  );
}
