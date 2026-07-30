import 'dart:async';

import 'package:asleep_sdk_flutter/asleep_sdk_flutter.dart';
import 'package:flutter/material.dart';

void main() => runApp(const AsleepExampleApp());

class AsleepExampleApp extends StatelessWidget {
  const AsleepExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: AsleepExamplePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AsleepExamplePage extends StatefulWidget {
  const AsleepExamplePage({super.key});

  @override
  State<AsleepExamplePage> createState() => _AsleepExamplePageState();
}

class _AsleepExamplePageState extends State<AsleepExamplePage> {
  final AsleepClient _client = AsleepClient();
  final TextEditingController _apiKeyController = TextEditingController();

  StreamSubscription<AsleepSnapshot>? _stateSubscription;
  StreamSubscription<AsleepEvent>? _eventSubscription;
  AsleepSnapshot _snapshot = const AsleepSnapshot();
  String _lastEvent = 'No events yet';
  String? _operationError;

  @override
  void initState() {
    super.initState();
    _stateSubscription = _client.states.listen((snapshot) {
      if (mounted) {
        setState(() => _snapshot = snapshot);
      }
    });
    _eventSubscription = _client.events.listen((event) {
      if (mounted) {
        setState(() => _lastEvent = event.runtimeType.toString());
      }
    });
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _eventSubscription?.cancel();
    _apiKeyController.dispose();
    unawaited(_client.dispose());
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _operationError = null);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _operationError = error.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canStop =
        _snapshot.isTracking ||
        (_snapshot.error?.category == AsleepErrorCategory.recordingDead &&
            !_snapshot.didClose);
    return Scaffold(
      appBar: AppBar(title: const Text('Asleep SDK')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          TextField(
            controller: _apiKeyController,
            decoration: const InputDecoration(
              labelText: 'API key',
              helperText: 'Kept in memory by this example only.',
            ),
            obscureText: true,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                onPressed: () => _run(() async {
                  final apiKey = _apiKeyController.text.trim();
                  if (apiKey.isEmpty) {
                    throw const AsleepException(
                      AsleepErrorCode.invalidState,
                      'Enter an API key first.',
                    );
                  }
                  await _client.initialize(AsleepSetupOptions(apiKey: apiKey));
                  await _client.checkAndRestoreTracking();
                  await _client.checkBatteryOptimization();
                }),
                child: const Text('Initialize'),
              ),
              OutlinedButton(
                onPressed: () => _run(() async {
                  final granted = await _client.hasRequiredPermissions();
                  if (!granted) {
                    await _client.requestRequiredPermissions();
                  }
                }),
                child: const Text('Check permission'),
              ),
              FilledButton.tonal(
                onPressed: canStop ? null : () => _run(_client.startTracking),
                child: const Text('Start'),
              ),
              FilledButton.tonal(
                onPressed: canStop ? () => _run(_client.stopTracking) : null,
                child: const Text('Stop'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _StatusRow('Setup', _snapshot.setupStatus.name),
          _StatusRow('Tracking', _snapshot.trackingStatus.name),
          _StatusRow('Session', _snapshot.sessionId ?? 'none'),
          _StatusRow('Last event', _lastEvent),
          if (_snapshot.error case final error?)
            _StatusRow('SDK error', '${error.code}: ${error.message}'),
          if (_operationError case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 96, child: Text(label)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
