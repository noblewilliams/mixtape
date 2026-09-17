import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Owns only an unsaved name. Canonical session/queue data stays with callers.
class MixNameEditor extends StatefulWidget {
  const MixNameEditor({
    super.key,
    required this.sessionId,
    required this.title,
    required this.onSave,
    required this.onFinished,
  });
  final String sessionId;
  final String title;
  final Future<bool> Function(String) onSave;
  final VoidCallback onFinished;
  @override
  State<MixNameEditor> createState() => _MixNameEditorState();
}

class _MixNameEditorState extends State<MixNameEditor> {
  late final _name = TextEditingController(text: widget.title);
  final _focus = FocusNode();
  bool _busy = false;
  bool _failed = false;
  bool _finished = false;
  @override
  void initState() {
    super.initState();
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _name.text.length,
    );
    _focus.addListener(_blur);
  }

  void _blur() {
    if (!_focus.hasFocus &&
        !_busy &&
        !_failed &&
        !_finished &&
        (ModalRoute.of(context)?.isCurrent ?? true)) {
      _save();
    }
  }

  void _finish() {
    if (_busy || _finished) return;
    _finished = true;
    widget.onFinished();
  }

  Future<void> _save() async {
    if (_busy || _finished) return;
    final title = _name.text.trim();
    if (title.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    if (title == widget.title) {
      _finish();
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    var saved = false;
    try {
      saved = await widget.onSave(title);
    } catch (_) {
      /* Retain the draft. */
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !saved;
    });
    if (saved) _finish();
  }

  @override
  void dispose() {
    _focus.removeListener(_blur);
    _focus.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        _finish();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: ValueKey('mix-rename-${widget.sessionId}'),
          controller: _name,
          focusNode: _focus,
          autofocus: true,
          readOnly: _busy,
          maxLength: 60,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(
            labelText: 'Mix name',
            counterText: '',
            errorText: _failed ? 'Couldn’t save the name.' : null,
          ),
        ),
        if (_failed)
          TextButton(
            key: ValueKey('mix-rename-retry-${widget.sessionId}'),
            onPressed: _busy ? null : _save,
            child: const Text('Retry'),
          ),
      ],
    ),
  );
}
