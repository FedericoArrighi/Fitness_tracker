import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'db.dart';
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

/// Keeps a page of a tab view alive, so that it is not rebuilt (and does not
/// reload its data) every time you switch tabs.
class KeepAlivePage extends StatefulWidget {
  final Widget child;
  const KeepAlivePage({super.key, required this.child});

  @override
  State<KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// A screen with an app bar and tabs. Pages are built when first opened and
/// then kept; a page is rebuilt (reloading its data) when you come back to it
/// after data changed elsewhere in the app.
class SectionTabs extends StatefulWidget {
  final String title;
  final List<String> tabs;
  final List<Widget Function(BuildContext)> pages;
  final List<Widget> actions;
  const SectionTabs({
    super.key,
    required this.title,
    required this.tabs,
    required this.pages,
    this.actions = const [],
  });

  @override
  State<SectionTabs> createState() => _SectionTabsState();
}

class _SectionTabsState extends State<SectionTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _tc;
  late final List<int> _keys;
  late final List<int> _stamps;

  @override
  void initState() {
    super.initState();
    _tc = TabController(length: widget.tabs.length, vsync: this);
    _keys = List.filled(widget.tabs.length, 0);
    _stamps = List.filled(widget.tabs.length, AppDb.stamp);
    _tc.addListener(_onTab);
  }

  void _onTab() {
    if (_tc.indexIsChanging) return;
    final i = _tc.index;
    if (_stamps[i] != AppDb.stamp) {
      setState(() {
        _keys[i]++;
        _stamps[i] = AppDb.stamp;
      });
    }
  }

  @override
  void dispose() {
    _tc.removeListener(_onTab);
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: widget.actions,
        bottom: TabBar(
          controller: _tc,
          isScrollable: widget.tabs.length > 3,
          tabs: [for (final t in widget.tabs) Tab(text: t)],
        ),
      ),
      body: TabBarView(
        controller: _tc,
        // switching by tapping the tabs only, so that swiping on a chart
        // does not change the tab
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < widget.pages.length; i++)
            KeepAlivePage(
              key: ValueKey('page$i-${_keys[i]}'),
              child: widget.pages[i](context),
            ),
        ],
      ),
    );
  }
}
