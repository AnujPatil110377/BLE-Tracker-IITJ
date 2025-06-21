import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'package:pointycastle/export.dart';
import 'package:pointycastle/api.dart' show InvalidCipherTextException;
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:asn1lib/asn1lib.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:basic_utils/basic_utils.dart';

class CryptoService {
  static final ECDomainParameters _params = ECDomainParameters('prime256v1');
  static const _kdfInfo = [109, 121, 95, 97, 112, 112, 95, 101, 110, 99, 114, 121, 112, 116, 105, 111, 110]; // "my_app_encryption"

  /// Generates a new ECC public/private key pair asynchronously.
  static Future<AsymmetricKeyPair<ECPublicKey, ECPrivateKey>> generateKeyPair() async {
    print('Generating ECC key pair (P-256)...');
    final keyParams = ECKeyGeneratorParameters(_params);
    final random = FortunaRandom();
    final seed = List<int>.generate(32, (i) => DateTime.now().millisecondsSinceEpoch % 256);
    random.seed(KeyParameter(Uint8List.fromList(seed)));
    final generator = ECKeyGenerator();
    generator.init(ParametersWithRandom(keyParams, random));
    final pair = generator.generateKeyPair();
    print('ECC key pair generated.');
    return pair;
  }

  /// Performs ECDH key exchange and derives a 32-byte symmetric key using HKDF.
  static Future<Uint8List> performKeyExchange(ECPrivateKey myPrivateKey, ECPublicKey peerPublicKey) async {
    final ecdh = ECDHBasicAgreement()..init(myPrivateKey);
    final sharedSecret = ecdh.calculateAgreement(peerPublicKey);

    final hkdf = crypto.Hkdf(
      hmac: crypto.Hmac.sha256(),
      outputLength: 32,
    );
    final secretKey = await hkdf.deriveKey(
      secretKey: crypto.SecretKey(_bigIntToBytes(sharedSecret)),
      info: _kdfInfo,
    );
    return Uint8List.fromList(await secretKey.extractBytes());
  }

  /// Encrypts plaintext data using AES-GCM.
  /// Returns a map containing the IV and the ciphertext (with tag).
  static Map<String, Uint8List> encryptData(Uint8List key, String plaintext) {
    final iv = _getSecureRandomBytes(12);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List.fromList(_kdfInfo)));

    final plainBytes = utf8.encode(plaintext);
    final cipherText = gcm.process(plainBytes);

    return {'iv': iv, 'ciphertext': cipherText};
  }

  /// Decrypts data using AES-GCM.
  /// Throws an exception if decryption fails.
  static String decryptData(Uint8List key, Uint8List iv, Uint8List ciphertextWithTag) {
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List.fromList(_kdfInfo)));

    try {
      final decryptedBytes = gcm.process(ciphertextWithTag);
      return utf8.decode(decryptedBytes);
    } on InvalidCipherTextException {
      throw Exception("Decryption failed: Invalid tag or ciphertext.");
    }
  }

  /// Checks if the EID is valid (exists and not registered) in Firestore.
  static Future<bool> isEidValid(String eid) async {
    final doc = await FirebaseFirestore.instance.collection('trackers').doc(eid).get();
    // EID is valid if the document exists and is not registered
    return doc.exists && (doc.data()?['registered'] != true);
  }

  /// Marks the EID as registered in Firestore.
  static Future<void> markEidAsRegistered(String eid) async {
    await FirebaseFirestore.instance.collection('trackers').doc(eid).set(
      {'registered': true},
      SetOptions(merge: true),
    );
  }

  /// Serializes the private key to a base64 string.
  static String serializePrivateKey(ECPrivateKey privateKey) {
    print('Serializing private key to base64...');
    final dBytes = privateKey.d!.toRadixString(16).padLeft(64, '0');
    final b64 = base64Encode(utf8.encode(dBytes));
    print('Private key base64: $b64');
    return b64;
  }

  /// Serializes the public key to a base64 string.
  static String serializePublicKey(ECPublicKey publicKey) {
    print('Serializing public key to base64...');
    final q = publicKey.Q!.getEncoded(false);
    final b64 = base64Encode(q);
    print('Public key base64: $b64');
    return b64;
  }

  /// Deserializes the private key from a base64 string.
  static ECPrivateKey deserializePrivateKey(String b64) {
    print('Deserializing private key from base64...');
    final dStr = utf8.decode(base64Decode(b64));
    final d = BigInt.parse(dStr, radix: 16);
    final key = ECPrivateKey(d, _params);
    print('Private key deserialized.');
    return key;
  }

  /// Deserializes the public key from a base64 string.
  static ECPublicKey deserializePublicKey(String b64) {
    print('Deserializing public key from base64...');
    final bytes = base64Decode(b64);
    final q = _params.curve.decodePoint(bytes);
    final key = ECPublicKey(q, _params);
    print('Public key deserialized.');
    return key;
  }

  /// Encrypts a string payload with the given ECPublicKey using ECDH + AES-GCM (ECIES-like)
  static String encryptWithPublicKey(ECPublicKey publicKey, String plaintext) {
    // Generate ephemeral key pair
    final params = ECDomainParameters('prime256v1');
    final keyParams = ECKeyGeneratorParameters(params);
    final random = FortunaRandom();
    final seed = List<int>.generate(32, (i) => DateTime.now().millisecondsSinceEpoch % 256);
    random.seed(KeyParameter(Uint8List.fromList(seed)));
    final generator = ECKeyGenerator();
    generator.init(ParametersWithRandom(keyParams, random));
    final ephemeralKeyPair = generator.generateKeyPair();
    final ephemeralPrivateKey = ephemeralKeyPair.privateKey as ECPrivateKey;
    final ephemeralPublicKey = ephemeralKeyPair.publicKey as ECPublicKey;

    // ECDH shared secret (fix: use ECPoint multiplication)
    final sharedSecret = (publicKey.Q! * ephemeralPrivateKey.d!)!.getEncoded();

    // Derive AES key from shared secret (SHA-256)
    final aesKey = Digest('SHA-256').process(Uint8List.fromList(sharedSecret));

    // Encrypt plaintext with AES-GCM
    final iv = Uint8List(12);
    for (int i = 0; i < iv.length; i++) {
      iv[i] = random.nextUint8();
    }
    final gcm = GCMBlockCipher(AESEngine());
    final aeadParams = AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0));
    gcm.init(true, aeadParams);
    final input = utf8.encode(plaintext);
    final cipherText = gcm.process(Uint8List.fromList(input));

    // Output: ephemeral public key + iv + ciphertext (all base64)
    final ephemeralPubBytes = ephemeralPublicKey.Q!.getEncoded(false);
    final out = jsonEncode({
      'ephemeral': base64Encode(ephemeralPubBytes),
      'iv': base64Encode(iv),
      'ct': base64Encode(cipherText),
    });
    return out;
  }

  // --- Utility Functions ---
  static SecureRandom _getSecureRandom() {
    final secureRandom = FortunaRandom();
    final seed = Uint8List.fromList(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
    secureRandom.seed(KeyParameter(seed));
    return secureRandom;
  }

  static Uint8List _getSecureRandomBytes(int len) {
    final random = Random.secure();
    return Uint8List.fromList(List<int>.generate(len, (_) => random.nextInt(256)));
  }

  static Uint8List _bigIntToBytes(BigInt number) {
    final bytes = number.toRadixString(16).padLeft(64, '0');
    return Uint8List.fromList(List<int>.generate(bytes.length ~/ 2,
        (i) => int.parse(bytes.substring(i * 2, i * 2 + 2), radix: 16)));
  }
}
