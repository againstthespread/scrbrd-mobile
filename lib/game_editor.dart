import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'console_device_transport.dart';
import 'device_transport.dart';
import 'game_data.dart';
import 'game_packet_serializer.dart';

class GameEditor extends StatefulWidget {
  const GameEditor({
    super.key,
    this.initialGameData,
    this.previewInitially = false,
    this.transport = const ConsoleDeviceTransport(),
    this.serializer = const GamePacketSerializer(),
    this.onPacketSent,
  });

  final GameData? initialGameData;
  final bool previewInitially;
  final DeviceTransport transport;
  final GamePacketSerializer serializer;
  final ValueChanged<GameData>? onPacketSent;

  @override
  State<GameEditor> createState() => _GameEditorState();
}

class _GameEditorState extends State<GameEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _leagueController;
  late final TextEditingController _awayTeamController;
  late final TextEditingController _homeTeamController;
  late final TextEditingController _awayScoreController;
  late final TextEditingController _homeScoreController;
  late final TextEditingController _clockController;

  late String _status;
  String? _packetPreview;

  @override
  void initState() {
    super.initState();

    final initialGameData =
        widget.initialGameData ??
        const GameData(
          league: 'NFL',
          awayTeam: 'Bills',
          homeTeam: 'Patriots',
          awayScore: 17,
          homeScore: 24,
          status: 'LIVE',
          clock: 'Q4 8:31',
        );

    _leagueController = TextEditingController(text: initialGameData.league);
    _awayTeamController = TextEditingController(text: initialGameData.awayTeam);
    _homeTeamController = TextEditingController(text: initialGameData.homeTeam);
    _awayScoreController = TextEditingController(
      text: initialGameData.awayScore.toString(),
    );
    _homeScoreController = TextEditingController(
      text: initialGameData.homeScore.toString(),
    );
    _clockController = TextEditingController(text: initialGameData.clock);
    _status = initialGameData.status;

    if (widget.previewInitially) {
      _packetPreview = widget.serializer.serializeToString(initialGameData);
    }
  }

  @override
  void dispose() {
    _leagueController.dispose();
    _awayTeamController.dispose();
    _homeTeamController.dispose();
    _awayScoreController.dispose();
    _homeScoreController.dispose();
    _clockController.dispose();
    super.dispose();
  }

  void _previewPacket() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    try {
      final gameData = _buildGameDataFromForm();

      setState(() {
        _packetPreview = widget.serializer.serializeToString(gameData);
      });
    } on GamePacketValidationException catch (error) {
      _showFeedback(error.message, isError: true);
    }
  }

  Future<void> _sendPacket() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    try {
      final gameData = _buildGameDataFromForm();
      final packetPreview = widget.serializer.serializeToString(gameData);
      await widget.transport.sendGameData(gameData);

      if (!mounted) {
        return;
      }

      setState(() {
        _packetPreview = packetPreview;
      });
      widget.onPacketSent?.call(gameData);
      _showFeedback('Game packet sent to console transport.');
    } on GamePacketValidationException catch (error) {
      _showFeedback(error.message, isError: true);
    } on Object catch (error) {
      _showFeedback('Unable to send packet: $error', isError: true);
    }
  }

  GameData _buildGameDataFromForm() {
    return GameData(
      league: _leagueController.text.trim(),
      awayTeam: _awayTeamController.text.trim(),
      homeTeam: _homeTeamController.text.trim(),
      awayScore: int.parse(_awayScoreController.text.trim()),
      homeScore: int.parse(_homeScoreController.text.trim()),
      status: _status,
      clock: _clockController.text.trim(),
      statusDetail: widget.initialGameData?.statusDetail,
      scheduledStartTime: widget.initialGameData?.scheduledStartTime,
      eventId: widget.initialGameData?.eventId,
    );
  }

  void _showFeedback(String message, {bool isError = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? colorScheme.error : null,
      ),
    );
  }

  String? _requiredTextValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Required';
    }

    return null;
  }

  String? _scoreValidator(String? value) {
    final trimmedValue = value?.trim() ?? '';
    final score = int.tryParse(trimmedValue);

    if (trimmedValue.isEmpty) {
      return 'Required';
    }

    if (score == null || score < 0) {
      return 'Enter a non-negative whole number';
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Game Packet',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Build one mock update for the ESP32 preview.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              _TextField(
                controller: _leagueController,
                label: 'League',
                validator: _requiredTextValidator,
              ),
              const SizedBox(height: 12),
              _TextField(
                controller: _awayTeamController,
                label: 'Away team',
                validator: _requiredTextValidator,
              ),
              const SizedBox(height: 12),
              _TextField(
                controller: _homeTeamController,
                label: 'Home team',
                validator: _requiredTextValidator,
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final useTwoColumns = constraints.maxWidth >= 420;
                  final fields = [
                    _TextField(
                      controller: _awayScoreController,
                      label: 'Away score',
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: _scoreValidator,
                    ),
                    _TextField(
                      controller: _homeScoreController,
                      label: 'Home score',
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: _scoreValidator,
                    ),
                  ];

                  if (!useTwoColumns) {
                    return Column(
                      children: [
                        fields.first,
                        const SizedBox(height: 12),
                        fields.last,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: fields.first),
                      const SizedBox(width: 12),
                      Expanded(child: fields.last),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Status',
                ),
                items: const [
                  DropdownMenuItem(value: 'UPCOMING', child: Text('UPCOMING')),
                  DropdownMenuItem(value: 'LIVE', child: Text('LIVE')),
                  DropdownMenuItem(value: 'FINAL', child: Text('FINAL')),
                ],
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }

                  setState(() {
                    _status = value;
                  });
                },
              ),
              const SizedBox(height: 12),
              _TextField(
                controller: _clockController,
                label: 'Clock or game detail',
                validator: _requiredTextValidator,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _previewPacket,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: const Text('Preview Packet'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _sendPacket,
                icon: const Icon(Icons.send),
                label: const Text('Send to Device'),
              ),
              if (_packetPreview != null) ...[
                const SizedBox(height: 20),
                Text(
                  'JSON Preview',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    _packetPreview!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.controller,
    required this.label,
    required this.validator,
    this.keyboardType,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String label;
  final String? Function(String?) validator;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: label,
      ),
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      textInputAction: TextInputAction.next,
      validator: validator,
    );
  }
}
