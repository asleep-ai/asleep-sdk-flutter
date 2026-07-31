import 'dart:async';

import 'package:flutter/material.dart';

import 'diagnostic_controller.dart';

/// Diagnostic application for the complete public Asleep SDK lifecycle.
class AsleepExampleApp extends StatefulWidget {
  const AsleepExampleApp({super.key, this.controller})
    : ownsController = controller == null,
      closeController = null;

  @visibleForTesting
  const AsleepExampleApp.owned({
    super.key,
    required this.controller,
    this.closeController,
  }) : assert(controller != null),
       ownsController = true;

  final DiagnosticController? controller;
  final bool ownsController;
  @visibleForTesting
  final Future<void> Function(DiagnosticController controller)? closeController;

  @override
  State<AsleepExampleApp> createState() => _AsleepExampleAppState();
}

class _AsleepExampleAppState extends State<AsleepExampleApp> {
  late final DiagnosticController _controller =
      widget.controller ?? DiagnosticController.forCurrentPlatform();

  @override
  void dispose() {
    if (widget.ownsController) {
      unawaited(_closeWithoutThrowing());
    }
    super.dispose();
  }

  Future<void> _closeWithoutThrowing() async {
    try {
      await (widget.closeController?.call(_controller) ?? _controller.close());
    } catch (error) {
      // Widget disposal cannot await or surface asynchronous cleanup failures.
      // Do not print the error because native details may contain sensitive data.
      debugPrint(
        'Asleep diagnostic cleanup failed (${error.runtimeType}); '
        'all cleanup steps were attempted.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: DiagnosticPage(controller: _controller),
      debugShowCheckedModeBanner: false,
    );
  }
}

class DiagnosticPage extends StatefulWidget {
  const DiagnosticPage({required this.controller, super.key});

  final DiagnosticController controller;

  @override
  State<DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<DiagnosticPage>
    with WidgetsBindingObserver {
  bool _deletionFlowInFlight = false;
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _sessionId = TextEditingController(
    text: 'session-id',
  );
  final TextEditingController _fromDate = TextEditingController(
    text: '2026-07-01',
  );
  final TextEditingController _toDate = TextEditingController(
    text: '2026-07-31',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(widget.controller.handleLifecycleState(state));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _apiKey.dispose();
    _sessionId.dispose();
    _fromDate.dispose();
    _toDate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final snapshot = controller.snapshot;
        final trackedSessionId = controller.lastTrackedSessionId;
        return Scaffold(
          appBar: AppBar(title: const Text('Asleep SDK diagnostic')),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: <Widget>[
              const Text(
                'Use a non-production account. Diagnostic logging can contain '
                'sensitive SDK context and is never rendered by this app.',
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('api-key'),
                controller: _apiKey,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Runtime API key',
                  helperText: 'Passed to one command, then cleared.',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: controller.canPrepareSdk
                    ? () {
                        final runtimeApiKey = _apiKey.text;
                        _apiKey.clear();
                        unawaited(
                          controller.initializeOrRestore(runtimeApiKey),
                        );
                      }
                    : null,
                child: const Text('Initialize / restore'),
              ),
              const Divider(height: 32),
              const Text('Permissions and Android battery settings'),
              _ButtonWrap(
                children: <Widget>[
                  OutlinedButton(
                    onPressed: controller.canManagePermissions
                        ? () => unawaited(controller.checkPermissions())
                        : null,
                    child: const Text('Check permissions'),
                  ),
                  OutlinedButton(
                    onPressed: controller.canManagePermissions
                        ? () => unawaited(controller.requestPermissions())
                        : null,
                    child: const Text('Request permissions'),
                  ),
                  OutlinedButton(
                    onPressed:
                        controller.hostPlatform ==
                            DiagnosticHostPlatform.android
                        ? () => unawaited(controller.openBatterySettings())
                        : null,
                    child: const Text('Open battery settings'),
                  ),
                  OutlinedButton(
                    onPressed: () =>
                        unawaited(controller.recheckBatteryOptimization()),
                    child: const Text('Recheck battery'),
                  ),
                ],
              ),
              const Divider(height: 32),
              const Text('Tracking and analysis'),
              _ButtonWrap(
                children: <Widget>[
                  FilledButton.tonal(
                    onPressed: controller.canStartTracking
                        ? () => unawaited(controller.startTracking())
                        : null,
                    child: const Text('Start tracking'),
                  ),
                  FilledButton.tonal(
                    onPressed: controller.canResumeTracking
                        ? () => unawaited(controller.resumeTracking())
                        : null,
                    child: const Text('Resume tracking'),
                  ),
                  FilledButton.tonal(
                    onPressed: controller.canStopTracking
                        ? () => unawaited(controller.stopTracking())
                        : null,
                    child: const Text('Stop tracking'),
                  ),
                  OutlinedButton(
                    onPressed: controller.canReconcileTracking
                        ? () => unawaited(controller.reconcileTrackingState())
                        : null,
                    child: const Text('Recheck tracking state'),
                  ),
                  OutlinedButton(
                    onPressed: controller.canRequestAnalysis
                        ? () => unawaited(controller.requestAnalysis())
                        : null,
                    child: const Text('Request analysis'),
                  ),
                ],
              ),
              if (controller.recoveryAwaitingUpload)
                const Text(
                  'Recovery requested; waiting for a later tracking upload.',
                ),
              const Divider(height: 32),
              const Text('Current / recent session ID'),
              SelectableText(
                controller.lastTrackedSessionId ?? 'not available',
                key: const Key('tracked-session-id'),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: trackedSessionId == null
                      ? null
                      : () => _sessionId.text = trackedSessionId,
                  child: const Text('Use tracked session'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('session-id-field'),
                controller: _sessionId,
                decoration: const InputDecoration(labelText: 'Session ID'),
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _fromDate,
                      decoration: const InputDecoration(
                        labelText: 'From (YYYY-MM-DD)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _toDate,
                      decoration: const InputDecoration(
                        labelText: 'To (YYYY-MM-DD)',
                      ),
                    ),
                  ),
                ],
              ),
              _ButtonWrap(
                children: <Widget>[
                  OutlinedButton(
                    onPressed: () =>
                        unawaited(controller.loadReport(_sessionId.text)),
                    child: const Text('Detailed report'),
                  ),
                  OutlinedButton(
                    onPressed: () => unawaited(
                      controller.loadReportList(_fromDate.text, _toDate.text),
                    ),
                    child: const Text('Report list'),
                  ),
                  OutlinedButton(
                    onPressed: () => unawaited(
                      controller.loadAverageReport(
                        _fromDate.text,
                        _toDate.text,
                      ),
                    ),
                    child: const Text('Average report'),
                  ),
                  OutlinedButton(
                    onPressed:
                        _deletionFlowInFlight || controller.deletionInFlight
                        ? null
                        : () => unawaited(_confirmDeletion(context)),
                    child: const Text('Delete session'),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Native diagnostic logging'),
                subtitle: const Text(
                  'Debug log payloads are intentionally not shown.',
                ),
                value: controller.loggingEnabled,
                onChanged: (enabled) =>
                    unawaited(controller.setLoggingEnabled(enabled)),
              ),
              const Divider(height: 32),
              _StatusRow('Setup', snapshot.setupStatus.name),
              _StatusRow('Tracking', snapshot.trackingStatus.name),
              _StatusRow(
                'Battery',
                controller.batteryStatus?.exempted.toString() ?? 'unchecked',
              ),
              _StatusRow('Permissions', switch (controller.permissionsGranted) {
                true => 'granted',
                false => 'denied',
                null => 'unchecked',
              }),
              _StatusRow('Last event', controller.lastEvent),
              _StatusRow(
                'Detailed report',
                controller.report == null ? 'not loaded' : 'loaded',
              ),
              _StatusRow(
                'Report list',
                '${controller.reportList.length} session(s)',
              ),
              if (controller.reportList.isNotEmpty) ...<Widget>[
                const Text('Report session IDs'),
                SelectableText(
                  controller.reportList.map((session) => session.id).join('\n'),
                  key: const Key('report-session-ids'),
                ),
              ],
              _StatusRow(
                'Average report',
                controller.averageReport == null ? 'not loaded' : 'loaded',
              ),
              _StatusRow(
                'Analysis result',
                controller.analysisResult == null ? 'not received' : 'received',
              ),
              if (controller.operationMessage case final message?)
                _StatusRow('Operation', message),
              if (controller.operationErrorText case final error?)
                Text(
                  error,
                  key: const Key('operation-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (controller.snapshotErrorText case final error?)
                Text(
                  error,
                  key: const Key('snapshot-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmDeletion(BuildContext context) async {
    if (_deletionFlowInFlight) {
      return;
    }
    final sessionId = _sessionId.text;
    setState(() => _deletionFlowInFlight = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Permanently delete this session?'),
          content: const Text(
            'This action is irreversible. The SDK does not provide an undo.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete permanently'),
            ),
          ],
        ),
      );
      if (!mounted) {
        return;
      }
      await widget.controller.deleteSession(
        sessionId,
        confirmed: confirmed ?? false,
      );
    } finally {
      if (mounted) {
        setState(() => _deletionFlowInFlight = false);
      }
    }
  }
}

class _ButtonWrap extends StatelessWidget {
  const _ButtonWrap({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(spacing: 8, runSpacing: 8, children: children),
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
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 120, child: Text(label)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
