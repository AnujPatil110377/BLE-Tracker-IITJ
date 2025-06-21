import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'services/crypto_service.dart';
import 'package:flutter/material.dart';

Future<void> registerEidAndKeys(String eid, {BuildContext? context}) async {
  print('Starting registration for EID: $eid');
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    print('User not signed in');
    if (context != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to add a tracker.')),
      );
    }
    throw Exception('User not signed in');
  }
  final email = user.email;
  final userName = user.displayName;
  final userId = user.uid;
  print('User info: userId=$userId, email=$email, userName=$userName');

  try {
    final firestore = FirebaseFirestore.instance;
    // Always check registration status from Firestore
    final eidDoc = await firestore.collection('trackers').doc(eid).get();
    print('EID doc exists: ${eidDoc.exists}');
    if (eidDoc.exists && (eidDoc.data()?['registered'] == true)) {
      print('This tracker is already registered (checked from Firestore).');
      if (context != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This tracker is already registered.')),
        );
      }
      throw Exception('This tracker is already registered.');
    }

    print('Generating ECC key pair...');
    final keyPair = await CryptoService.generateKeyPair();
    final publicKey = CryptoService.serializePublicKey(keyPair.publicKey);
    final privateKey = CryptoService.serializePrivateKey(keyPair.privateKey);
    print('Generated public key: $publicKey');
    print('Generated private key: $privateKey');

    if (publicKey.isEmpty) {
      print('Generated public key is empty!');
      throw Exception('Generated public key is empty!');
    }

    print('Storing private key securely...');
    await const FlutterSecureStorage().write(key: eid, value: privateKey);
    print('Private key stored.');

    print('Preparing Firestore batch write...');
    final batch = firestore.batch();
    final trackerRef = firestore.collection('trackers').doc(eid);
    batch.set(trackerRef, {
      'publicKey': publicKey,
      'registered': true,
      'data': {
        'location+time': [], // now an empty array
      },
      eid: publicKey, // EID as key, publicKey as value
    }, SetOptions(merge: true));
    final userRef = firestore.collection('User').doc(userId);
    batch.set(userRef, {
      'User_Name': userName,
      'email': email,
      'trackers': {eid: publicKey},
    }, SetOptions(merge: true));

    await batch.commit().then((_) {
      print('Batch write committed successfully.');
      if (context != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Tracker $eid registered successfully!')),
        );
      }
    }).catchError((e) {
      print('Error during batch registration: $e');
      if (context != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error registering tracker: $e')),
        );
      }
      throw Exception('Error during batch registration: $e');
    });
    print('Registration complete for EID: $eid');
  } catch (e) {
    print('Exception during registration: $e');
    rethrow;
  }
}
