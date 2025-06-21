import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'crypto_service.dart';

Future<void> registerTracker(BuildContext context, String eid) async {
  // 1. Check if tracker already exists
  final doc = await FirebaseFirestore.instance.collection('trackers').doc(eid).get();
  if (doc.exists) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('This tracker is already registered.')),
    );
    return;
  }

  // 2. Generate ECC key pair
  final keyPair = await CryptoService.generateKeyPair();

  // 3. Store private key securely
  final storablePrivateKey = CryptoService.serializePrivateKey(keyPair.privateKey);
  await const FlutterSecureStorage().write(key: eid, value: storablePrivateKey);

  // 4. Upload public key to Firestore
  final storablePublicKey = CryptoService.serializePublicKey(keyPair.publicKey);
  final userId = FirebaseAuth.instance.currentUser?.uid;
  await FirebaseFirestore.instance.collection('trackers').doc(eid).set({
    'publicKey': storablePublicKey,
    'ownerId': userId,
    'deviceName': 'New Tracker',
  });

  // 5. (Optional) Update user's tracker list
  if (userId != null) {
    final userDoc = FirebaseFirestore.instance.collection('users').doc(userId);
    await userDoc.update({
      'ownedTrackers': FieldValue.arrayUnion([eid])
    }).catchError((_) {
      // If the field doesn't exist, create it
      userDoc.set({'ownedTrackers': [eid]}, SetOptions(merge: true));
    });
  }

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Tracker registered successfully!')),
  );
}
