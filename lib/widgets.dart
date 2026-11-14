import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'nutrients.dart';

/// A text field that only accepts numbers (digits, comma, dot).
Widget numField({
  required TextEditingController controller,
  required String label,
  String? suffix,
  void Function(String)? onChanged,
  void Function(String)? onSubmitted,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextField(
      controller: controller,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}

/// Asks for an amount in grams. Enter confirms. Returns null if cancelled.
Future<double?> askGrams(BuildContext context, String title,
    {String initial = '100'}) {
  final ctl = TextEditingController(text: initial);
  // Select the default text so typing replaces it.
  ctl.selection = TextSelection(baseOffset: 0, extentOffset: ctl.text.length);
  return showDialog<double>(
    context: context,
    builder: (context) {
      void submit() {
        final g = parseNum(ctl.text);
        if (g != null && g > 0) Navigator.pop(context, g);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => submit(),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration:
              const InputDecoration(labelText: 'Amount', suffixText: 'g'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(onPressed: submit, child: const Text('OK')),
        ],
      );
    },
  );
}
