import 'package:flutter/material.dart';
import 'register_eid.dart';

class AddTrackerScreen extends StatefulWidget {
  const AddTrackerScreen({Key? key}) : super(key: key);

  @override
  State<AddTrackerScreen> createState() => _AddTrackerScreenState();
}

class _AddTrackerScreenState extends State<AddTrackerScreen> {
  final TextEditingController _eidController = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _register() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await registerEidAndKeys(_eidController.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tracker registered successfully!')),
        );
        _eidController.clear();
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
    setState(() {
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Tracker')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _eidController,
              decoration: const InputDecoration(labelText: 'Enter EID'),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ElevatedButton(
              onPressed: _loading ? null : _register,
              child: _loading ? const CircularProgressIndicator() : const Text('Register'),
            ),
          ],
        ),
      ),
    );
  }
}
