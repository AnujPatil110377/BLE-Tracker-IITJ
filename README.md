
# BLE Beacon Tracker

## Overview

BLE Beacon Tracker is a cross-platform Flutter application for tracking, managing, and remotely buzzing ESP-based BLE tags. It leverages Firebase for authentication and data storage, and supports peer-to-peer BLE communication for real-time device discovery and control.

**Key Features:**
- Register and manage BLE tracker devices (EIDs)
- Remotely trigger a buzzer on ESP tags from the app
- Peer devices automatically detect and buzz nearby ESP tags with active flags
- Real-time location and status updates
- Google Sign-In authentication
- Background BLE scanning and notifications

## Architecture

- **Flutter**: UI and cross-platform logic
- **Firebase**: Firestore (data), Auth (user management), Storage (optional)
- **flutter_blue_plus**: BLE scanning and communication
- **ESP32/ESP BLE Tags**: Custom firmware for BLE advertising and buzzer
- **Background Services**: For continuous scanning and notifications

## Folder Structure

- `lib/`
  - `main.dart`: App entry point, Firebase initialization
  - `screens/`: UI screens (home, add tracker, etc.)
  - `services/`: BLE, crypto, and Firebase logic
  - `widgets/`: Reusable UI components (e.g., BuzzerButton)
  - `firebase_options.dart`: Firebase config for all platforms
- `android/`, `ios/`, `web/`, `linux/`, `macos/`, `windows/`: Platform-specific code
- `test/`: Widget and integration tests

## Setup & Installation

1. **Clone the repository:**
	```sh
	git clone https://github.com/AnujPatil110377/BLE-Tracker-IITJ.git
	cd BLE-Tracker-IITJ
	```
2. **Install dependencies:**
	```sh
	flutter pub get
	```
3. **Firebase Setup:**
	- Web: `lib/firebase_options.dart` is pre-configured. For other platforms, add your `google-services.json` (Android) or `GoogleService-Info.plist` (iOS) as needed.
	- Ensure your Firebase project matches the IDs in `firebase_options.dart`.
4. **Run the app:**
	```sh
	flutter run -d chrome   # For web
	flutter run -d android  # For Android
	flutter run -d ios      # For iOS
	```

## Usage

1. **Sign in:**
	- Use Google Sign-In to authenticate.
2. **Add a Tracker:**
	- Go to "Add Tracker", enter the EID, and register. ECC keys are generated and stored securely.
3. **View Trackers:**
	- The home screen lists all registered trackers with status, last ping, and location.
4. **Buzz a Tracker:**
	- Click the buzzer button next to a tracker to set its buzzer flag. Peer devices will detect and buzz the corresponding ESP tag.
5. **Background Scanning:**
	- The app runs a background service (on supported platforms) to monitor for active buzzer flags and nearby ESP tags.

## Core Components

- **ESPBLEService**: Handles BLE scanning, device discovery, and sending buzzer commands.
- **BuzzerButton**: UI widget to trigger the buzzer flag for a tracker.
- **TrackerHomeScreen**: Main dashboard for tracker management.
- **AddTrackerScreen**: Register new EIDs and generate ECC keys.
- **CryptoService**: ECC key generation, ECDH, and AES encryption for secure communication.

## Dependencies

Key packages:
- `flutter_blue_plus`, `geolocator`, `permission_handler`, `cloud_firestore`, `firebase_auth`, `firebase_core`, `flutter_background_service`, `flutter_local_notifications`, `google_sign_in`, `pointycastle`, `cryptography`, `asn1lib`, `flutter_secure_storage`, `basic_utils`

See `pubspec.yaml` for the full list.

## ESP BLE Tag Firmware

- ESP32/ESP8266 devices must run custom firmware to advertise EID and accept buzzer commands over BLE.
- EID pattern matching is used for discovery; no complex configuration required.
- See `/firmware` (if available) or contact the maintainer for sample code.

## Contributing

1. Fork the repo and create a feature branch.
2. Make your changes and add tests if possible.
3. Submit a pull request with a clear description.

## License

This project is licensed under the MIT License.

## Maintainer

- Anuj Patil ([AnujPatil110377](https://github.com/AnujPatil110377))
