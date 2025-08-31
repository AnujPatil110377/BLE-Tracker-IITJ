import 'package:flutter/material.dart';
import '../services/esp_ble_service.dart';

class BuzzerButton extends StatefulWidget {
  final String eid;
  final String trackerName;
  final bool? isESPConfigured;
  final VoidCallback? onBuzzerSent;

  const BuzzerButton({
    Key? key,
    required this.eid,
    required this.trackerName,
    this.isESPConfigured,
    this.onBuzzerSent,
  }) : super(key: key);

  @override
  State<BuzzerButton> createState() => _BuzzerButtonState();
}

class _BuzzerButtonState extends State<BuzzerButton> {
  bool _isSending = false;
  bool _hasActiveFlag = false;

  @override
  void initState() {
    super.initState();
    _checkBuzzerFlag();
  }

  Future<void> _checkBuzzerFlag() async {
    final hasFlag = await ESPBLEService.getBuzzerFlagStatus(widget.eid);
    if (mounted) {
      setState(() {
        _hasActiveFlag = hasFlag;
      });
    }
  }

  Future<void> _sendBuzzerCommand() async {
    if (_isSending || _hasActiveFlag) return;

    setState(() {
      _isSending = true;
    });

    try {
      // Simply set the buzzer flag - no configuration needed
      final success = await ESPBLEService.setBuzzerFlag(
        eid: widget.eid,
        enabled: true,
        duration: 5000, // 5 seconds
      );

      if (success) {
        setState(() {
          _hasActiveFlag = true;
        });
        
        widget.onBuzzerSent?.call();
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Buzzer flag set for ${widget.trackerName}'),
            backgroundColor: Colors.green,
          ),
        );

        // Auto-refresh flag status after expected duration
        Future.delayed(Duration(seconds: 8), () {
          if (mounted) _checkBuzzerFlag();
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to set buzzer flag'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  void _showConfigurationDialog() {
    // Configuration dialog no longer needed - keeping method for compatibility
    // The system now works automatically without configuration
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: _isSending
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
              ),
            )
          : Icon(
              _hasActiveFlag ? Icons.volume_up : Icons.notifications_active,
              color: _hasActiveFlag ? Colors.orange : Colors.blue,
              size: 20,
            ),
      onPressed: _isSending || _hasActiveFlag ? null : _sendBuzzerCommand,
      tooltip: _hasActiveFlag 
          ? 'Buzzer active' 
          : 'Send buzzer command to ${widget.trackerName}',
    );
  }
}

class ESPConfigurationDialog extends StatefulWidget {
  final String eid;
  final String trackerName;
  final VoidCallback? onConfigured;

  const ESPConfigurationDialog({
    Key? key,
    required this.eid,
    required this.trackerName,
    this.onConfigured,
  }) : super(key: key);

  @override
  State<ESPConfigurationDialog> createState() => _ESPConfigurationDialogState();
}

class _ESPConfigurationDialogState extends State<ESPConfigurationDialog> {
  final _deviceNameController = TextEditingController();
  final _serviceUuidController = TextEditingController();
  final _buzzerCharController = TextEditingController();
  
  String _commandFormat = 'json';
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    // Set default values
    _serviceUuidController.text = ESPBLEService.DEFAULT_ESP_SERVICE_UUID;
    _buzzerCharController.text = ESPBLEService.DEFAULT_BUZZER_CHARACTERISTIC_UUID;
    _deviceNameController.text = 'ESP-${widget.eid.substring(0, 6)}';
  }

  @override
  void dispose() {
    _deviceNameController.dispose();
    _serviceUuidController.dispose();
    _buzzerCharController.dispose();
    super.dispose();
  }

  Future<void> _saveConfiguration() async {
    setState(() {
      _isSaving = true;
    });

    try {
      final success = await ESPBLEService.configureESPDevice(
        eid: widget.eid,
        deviceName: _deviceNameController.text.trim().isNotEmpty 
            ? _deviceNameController.text.trim() 
            : null,
        serviceUuid: _serviceUuidController.text.trim().isNotEmpty 
            ? _serviceUuidController.text.trim() 
            : null,
        buzzerCharacteristicUuid: _buzzerCharController.text.trim().isNotEmpty 
            ? _buzzerCharController.text.trim() 
            : null,
        commandFormat: _commandFormat,
      );

      if (success) {
        widget.onConfigured?.call();
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ESP configuration saved for ${widget.trackerName}'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save ESP configuration'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Configure ESP Device'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tracker: ${widget.trackerName}'),
            SizedBox(height: 16),
            
            Text(
              'Configure ESP device for buzzer commands.\nThe ESP device should advertise with the EID or device name.',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            SizedBox(height: 16),
            
            TextField(
              controller: _deviceNameController,
              decoration: InputDecoration(
                labelText: 'Device Name Pattern',
                hintText: 'ESP-123456 (should contain EID)',
                border: OutlineInputBorder(),
                helperText: 'ESP device name containing the EID',
              ),
            ),
            SizedBox(height: 12),
            
            TextField(
              controller: _serviceUuidController,
              decoration: InputDecoration(
                labelText: 'Service UUID',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 12),
            
            TextField(
              controller: _buzzerCharController,
              decoration: InputDecoration(
                labelText: 'Buzzer Characteristic UUID',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 12),
            
            DropdownButtonFormField<String>(
              value: _commandFormat,
              decoration: InputDecoration(
                labelText: 'Command Format',
                border: OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(value: 'json', child: Text('JSON')),
                DropdownMenuItem(value: 'simple', child: Text('Simple (BUZZ:duration)')),
                DropdownMenuItem(value: 'binary', child: Text('Binary')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _commandFormat = value;
                  });
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSaving ? null : _saveConfiguration,
          child: _isSaving 
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('Save'),
        ),
      ],
    );
  }
}
