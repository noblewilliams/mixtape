import 'energy_journey.dart';
import 'dart:async';
import 'package:flutter/material.dart';

class MixPromptInput extends StatefulWidget {
  const MixPromptInput({
    super.key,
    required this.controller,
    required this.busy,
    required this.onSubmit,
    this.attachment,
  });
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSubmit;
  final Widget? attachment;

  @override
  State<MixPromptInput> createState() => _MixPromptInputState();
}

class _MixPromptInputState extends State<MixPromptInput>
    with WidgetsBindingObserver {
  static const _examples = [
    'A slow Sunday morning',
    'High-energy songs for my workout',
    'Dinner with friends, soft vocals',
    'More like my favourite soul songs',
    'A rainy drive home',
    'Instrumentals to help me focus',
  ];
  final _focus = FocusNode();
  late final Timer _timer;
  int _example = 0;
  bool _resumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.controller.addListener(_changed);
    _timer = Timer.periodic(const Duration(milliseconds: 4500), (_) {
      if (!mounted ||
          !_resumed ||
          widget.busy ||
          _focus.hasFocus ||
          widget.controller.text.isNotEmpty ||
          MediaQuery.disableAnimationsOf(context) ||
          !(ModalRoute.of(context)?.isCurrent ?? true)) {
        return;
      }
      setState(() => _example = (_example + 1) % _examples.length);
    });
  }

  void _changed() => setState(() {});

  @override
  void didUpdateWidget(MixPromptInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _resumed = state == AppLifecycleState.resumed;

  @override
  void dispose() {
    _timer.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    if (!widget.busy && widget.controller.text.trim().isNotEmpty) {
      widget.onSubmit();
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Describe your new mix',
    child: Container(
      decoration: widget.attachment == null
          ? null
          : BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outline),
              borderRadius: BorderRadius.circular(16),
            ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.attachment != null) widget.attachment!,
          EnergyControl(controller: widget.controller, enabled: !widget.busy),
          TextField(
            key: const Key('prompt-field'),
            controller: widget.controller,
            focusNode: _focus,
            readOnly: widget.busy,
            minLines: 1,
            maxLines: 3,
            maxLength: 2000,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: _examples[_example],
              counterText: '',
              contentPadding: widget.attachment == null
                  ? null
                  : const EdgeInsets.all(12),
              border: widget.attachment == null
                  ? OutlineInputBorder(borderRadius: BorderRadius.circular(16))
                  : InputBorder.none,
              suffixIcon: IconButton(
                key: const Key('start-session'),
                tooltip: 'Start new mix',
                onPressed: widget.busy || widget.controller.text.trim().isEmpty
                    ? null
                    : _submit,
                icon: widget.busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward),
                constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
