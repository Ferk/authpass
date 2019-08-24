import 'dart:isolate';

import 'package:authpass/bloc/kdbx_bloc.dart';
import 'package:authpass/main.dart';
import 'package:authpass/ui/common_fields.dart';
import 'package:authpass/ui/screens/select_file_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:isolate/isolate_runner.dart';
import 'package:kdbx/kdbx.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';

final _logger = Logger('password_list');

class PasswordList extends StatelessWidget {
  static Route<void> route() => MaterialPageRoute(
        settings: const RouteSettings(name: '/passwordList'),
        builder: (context) => PasswordList(),
      );

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = Provider.of<KdbxBloc>(context);
    final allEntries = kdbxBloc.openedFiles.expand((f) => f.body.rootGroup.getAllEntries()).toList(growable: false);
    return PasswordListContent(
      entries: allEntries,
    );
  }
}

enum OverFlowMenuItems {
  lock,
}

class PasswordListContent extends StatefulWidget {
  const PasswordListContent({Key key, this.entries}) : super(key: key);

  final List<KdbxEntry> entries;

  @override
  _PasswordListContentState createState() => _PasswordListContentState();
}

class PasswordListFilterIsolateRunner {
  static final _instance = PasswordListFilterIsolateRunner();

  List<KdbxEntry> _allEntries;

  static bool init(List<KdbxEntry> entries) {
    initIsolate();
    PasswordListFilterIsolateRunner._instance._allEntries = entries;
    return true;
  }

  static List<KdbxEntry> filter(String query) {
    _logger.info('We have to filter for $query');
    return PasswordListFilterIsolateRunner._instance._allEntries
        .where((entry) => matches(entry, query))
        .toList(growable: false);
  }

  static const searchFields = ['Title', 'URL', 'UserName'];

  static bool matches(KdbxEntry entry, String filterQuery) {
    final query = filterQuery.toLowerCase();
    return searchFields
        .where((field) => entry.strings[field]?.getText()?.toLowerCase()?.contains(query) == true)
        .isNotEmpty;
  }
}

class _PasswordListContentState extends State<PasswordListContent> {
  List<KdbxEntry> _filteredEntries;
  String _filterQuery;
  final _isolateRunner = IsolateRunner.spawn();

  @override
  void initState() {
    super.initState();
    _logger.finer('Initializing password list content.');
    _isolateRunner.then((runner) => runner.run(PasswordListFilterIsolateRunner.init, widget.entries)).then((result) {
      _logger.finer('Initializd filter isolate $result');
    });
  }

  @override
  void dispose() {
    _logger.info('Disposing isolate runner.');
    _isolateRunner.then<void>((runner) => runner.close());
    super.dispose();
  }

  AppBar _buildDefaultAppBar(BuildContext context) {
    return AppBar(
      title: const Text('AuthPass'),
      actions: <Widget>[
        IconButton(
            icon: Icon(Icons.search),
            onPressed: () {
              setState(() {
                _filteredEntries = widget.entries;
              });
            }),
        PopupMenuButton<OverFlowMenuItems>(
          onSelected: (item) {
            switch (item) {
              case OverFlowMenuItems.lock:
                Provider.of<KdbxBloc>(context).closeAllFiles();
                Navigator.of(context).pushAndRemoveUntil(SelectFileScreen.route, (_) => false);
                break;
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: OverFlowMenuItems.lock, child: Text('Lock Files')),
          ],
        )
      ],
    );
  }

  ThemeData appBarTheme(BuildContext context) {
    final theme = Theme.of(context);
    return theme.copyWith(
      primaryColor: Colors.white,
      primaryIconTheme: theme.primaryIconTheme.copyWith(color: Colors.grey),
      primaryColorBrightness: Brightness.light,
      primaryTextTheme: theme.textTheme,
    );
  }

  AppBar _buildFilterAppBar(BuildContext context) {
    final theme = appBarTheme(context);
    return AppBar(
      backgroundColor: theme.primaryColor,
      iconTheme: theme.primaryIconTheme,
      textTheme: theme.primaryTextTheme,
      brightness: theme.primaryColorBrightness,
      leading: IconButton(
        icon: Icon(Icons.arrow_back),
        onPressed: () {
          setState(() {
            _filteredEntries = null;
          });
        },
      ),
      title: TextField(
        style: theme.textTheme.title,
        onChanged: (newQuery) async {
          _logger.info('query changed to $newQuery');
          final entries = await _isolateRunner.then((runner) {
            _logger.info('Got runner, starting filter.');
            return runner.run(PasswordListFilterIsolateRunner.filter, newQuery);
          });
          setState(() {
            _filterQuery = newQuery;
            _filteredEntries = entries;
          });
        },
        autofocus: true,
        decoration: InputDecoration(
          hintText: 'Search',
          border: InputBorder.none,
          hintStyle: theme.inputDecorationTheme.hintStyle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final commonFields = Provider.of<CommonFields>(context);
    final entries = _filteredEntries ?? widget.entries;
    return Scaffold(
      appBar: _filteredEntries == null ? _buildDefaultAppBar(context) : _buildFilterAppBar(context),
      body: ListView.builder(
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          return ListTile(
            leading: Icon(Icons.lock_open),
            title: Text.rich(
                _highlightFilterQuery(commonFields.title.stringValue(entry)) ?? const TextSpan(text: '(no title)')),
//            subtitle: Text(commonFields.url.stringValue(entry) ?? '(no website)'),
            subtitle: Text.rich(_highlightFilterQuery(commonFields.userName.stringValue(entry)) ??
                const TextSpan(text: '(no website)')),
          );
        },
      ),
    );
  }

  InlineSpan _highlightFilterQuery(String text) {
    if (text == null) {
      return null;
    }
    if (_filterQuery == null || _filterQuery.isEmpty) {
      return TextSpan(text: text);
    }
    //RegExp.escape(text).allMatches(string)
    int previousMatchEnd = 0;
    List<TextSpan> spans = [];
    for (final match in _filterQuery.allMatches(text)) {
      spans.add(TextSpan(text: text.substring(previousMatchEnd, match.start)));
      spans.add(TextSpan(text: text.substring(match.start, match.end), style: TextStyle(fontWeight: FontWeight.bold)));
      previousMatchEnd = match.end;
    }
    if (previousMatchEnd < text.length) {
      spans.add(TextSpan(text: text.substring(previousMatchEnd)));
    }
    return TextSpan(children: spans);

//    The functional approach was a bit too clever...
//    int previousMatchEnd = 0;
//    return TextSpan(
//        children: _filterQuery.allMatches(text).expand((match) {
//      final spans = [
//        TextSpan(text: text.substring(previousMatchEnd, match.start)),
//        TextSpan(text: text.substring(match.start, match.end), style: TextStyle(fontWeight: FontWeight.bold)),
//      ];
//      previousMatchEnd = match.end;
//      return spans;
//    }).toList(growable: false));
  }
}
