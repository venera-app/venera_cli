import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:venera_core/venera_core.dart';

const version = '2.0.0';

Future<void> main(List<String> arguments) async {
  final cli = VeneraCli(stdout, stderr, stdin);
  exitCode = await cli.run(arguments);
}

class VeneraCli {
  final Stdout out;
  final IOSink err;
  final Stdin input;
  bool _coreInitialized = false;

  VeneraCli(this.out, this.err, this.input);

  Future<int> run(List<String> arguments) async {
    final parser = _rootParser();
    try {
      final results = parser.parse(arguments);
      if (results.flag('help')) {
        _printUsage(parser);
        return 0;
      }
      if (results.flag('version')) {
        out.writeln('venera $version');
        return 0;
      }
      final rest = results.rest;
      if (rest.isEmpty) {
        _printUsage(parser);
        return 64;
      }

      Log.setPrinter(null);
      Log.isMuted = true;
      await _initCore();

      switch (rest.first) {
        case 'source':
          return await _runSource(rest.skip(1).toList());
        default:
          return await _runComicCommand(rest);
      }
    } on FormatException catch (e) {
      err.writeln(e.message);
      err.writeln('');
      _printUsage(parser, sink: err);
      return 64;
    } catch (e) {
      err.writeln(e);
      return 1;
    } finally {
      Log.isMuted = false;
      if (_coreInitialized) {
        try {
          ComicSourceManager().dispose();
        } catch (_) {
          // ignore
        }
        _coreInitialized = false;
      }
    }
  }

  ArgParser _rootParser() {
    return ArgParser(allowTrailingOptions: false)
      ..addFlag(
        'help',
        abbr: 'h',
        negatable: false,
        help: 'Show usage information.',
      )
      ..addFlag(
        'version',
        abbr: 'v',
        negatable: false,
        help: 'Show version information.',
      );
  }

  Future<void> _initCore() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('HOME is not set');
    }
    final dataDir = Directory('$home${Platform.pathSeparator}.venera');
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }
    await ComicSourceManager().init(
      dataPath: dataDir.path,
      appVersion: version,
    );
    _coreInitialized = true;
  }

  Future<int> _runSource(List<String> arguments) async {
    if (arguments.isEmpty || arguments.first == 'help') {
      _printSourceUsage();
      return arguments.isEmpty ? 64 : 0;
    }

    switch (arguments.first) {
      case 'list':
        _ensureNoExtra(arguments, 1, 'venera source list');
        return _listSources();
      case 'load':
        return await _loadSource(arguments.skip(1).toList());
      case 'update':
        return await _updateSource(arguments.skip(1).toList());
      case 'delete':
        return await _deleteSource(arguments.skip(1).toList());
      default:
        throw FormatException('Unknown source command: ${arguments.first}');
    }
  }

  int _listSources() {
    final sources = ComicSource.all();
    if (sources.isEmpty) {
      out.writeln('No comic sources loaded.');
      return 0;
    }
    for (final source in sources) {
      final update = ComicSourceManager().availableUpdates[source.key];
      final updateText = update == null ? '' : ' -> $update';
      out.writeln(
        '${source.key}\t${source.name}\t${source.version}$updateText',
      );
    }
    return 0;
  }

  Future<int> _loadSource(List<String> arguments) async {
    final parser = ArgParser()
      ..addFlag(
        'force',
        abbr: 'f',
        negatable: false,
        help: 'Replace an existing source with the same key.',
      );
    final results = parser.parse(arguments);
    if (results.rest.length != 1) {
      err.writeln('Usage: venera source load [-f] <filepath/url>');
      err.writeln(parser.usage);
      return 64;
    }

    final target = results.rest.single;
    final replace = results.flag('force');
    final manager = ComicSourceManager();
    final source = _isUrl(target)
        ? await manager.installFromUrl(target, replace: replace)
        : await manager.installFromFile(target, replace: replace);
    out.writeln('Loaded ${source.key} (${source.name}) ${source.version}');
    return 0;
  }

  Future<int> _updateSource(List<String> arguments) async {
    if (arguments.length > 1) {
      err.writeln('Usage: venera source update [key]');
      return 64;
    }
    final manager = ComicSourceManager();
    if (arguments.isEmpty) {
      final updated = await manager.updateAllSources();
      if (updated.isEmpty) {
        out.writeln('All sources are up to date.');
      } else {
        for (final source in updated) {
          out.writeln('Updated ${source.key} to ${source.version}');
        }
      }
      return 0;
    }
    final source = await manager.updateSource(arguments.single);
    out.writeln('Updated ${source.key} to ${source.version}');
    return 0;
  }

  Future<int> _deleteSource(List<String> arguments) async {
    if (arguments.length != 1) {
      err.writeln('Usage: venera source delete <key>');
      return 64;
    }
    final key = arguments.single;
    final source = ComicSource.find(key);
    if (source == null) {
      err.writeln('source $key not found');
      return 1;
    }
    out.write('Delete ${source.key} (${source.name})? Type "yes" to confirm: ');
    final answer = input.readLineSync();
    if (answer != 'yes') {
      out.writeln('Cancelled.');
      return 0;
    }
    await ComicSourceManager().deleteSource(key);
    out.writeln('Deleted $key');
    return 0;
  }

  Future<int> _runComicCommand(List<String> arguments) async {
    if (arguments.length < 2) {
      _printComicUsage();
      return 64;
    }
    final source = ComicSource.find(arguments[0]);
    if (source == null) {
      err.writeln('source ${arguments[0]} not found');
      return 1;
    }
    final command = arguments[1];
    final rest = arguments.skip(2).toList();
    switch (command) {
      case 'account':
        _ensureNoExtra(arguments, 2, 'venera ${source.key} account');
        return _account(source);
      case 'login':
        return await _login(source, rest);
      case 'logout':
        _ensureNoExtra(arguments, 2, 'venera ${source.key} logout');
        return await _logout(source);
      case 'search':
        return await _search(source, rest);
      case 'info':
        return await _info(source, rest);
      case 'pages':
        return await _pages(source, rest);
      case 'explore':
        return await _explore(source, rest);
      default:
        throw FormatException('Unknown comic command: $command');
    }
  }

  int _account(ComicSource source) {
    final account = source.account;
    if (account == null) {
      out.writeln('source ${source.key} does not support account login');
      return 0;
    }
    out.writeln('source: ${source.key}');
    out.writeln('logged: ${source.isLogged ? 'yes' : 'no'}');
    final methods = <String>[
      if (account.login != null) 'password',
      if (account.loginWithCookies != null) 'cookies',
      if (account.loginWebsite != null) 'webview',
    ];
    out.writeln('methods: ${methods.isEmpty ? 'none' : methods.join(', ')}');
    if (account.cookieFields != null && account.cookieFields!.isNotEmpty) {
      out.writeln('cookie fields: ${account.cookieFields!.join(', ')}');
    }
    if (account.loginWebsite != null) {
      out.writeln('login website: ${account.loginWebsite}');
    }
    if (account.registerWebsite != null) {
      out.writeln('register website: ${account.registerWebsite}');
    }
    return 0;
  }

  Future<int> _login(ComicSource source, List<String> arguments) async {
    final account = source.account;
    if (account == null) {
      err.writeln('source ${source.key} does not support account login');
      return 1;
    }

    final parser = ArgParser()
      ..addOption('username', abbr: 'u')
      ..addOption('password', abbr: 'p')
      ..addMultiOption(
        'cookie',
        abbr: 'c',
        help: 'Cookie value as field=value. Repeat for multiple fields.',
      );
    final results = parser.parse(arguments);
    if (results.rest.isNotEmpty) {
      err.writeln(
        'Usage: venera ${source.key} login '
        '[--username name] [--password pwd] [--cookie field=value]',
      );
      err.writeln(parser.usage);
      return 64;
    }

    final cookies = results.multiOption('cookie');
    if (cookies.isNotEmpty) {
      return await _loginWithCookies(source, cookies);
    }
    return await _loginWithPassword(
      source,
      results.option('username'),
      results.option('password'),
    );
  }

  Future<int> _loginWithPassword(
    ComicSource source,
    String? username,
    String? password,
  ) async {
    final login = source.account?.login;
    if (login == null) {
      err.writeln('source ${source.key} does not support password login');
      return 1;
    }
    username ??= _prompt('Username: ');
    if (username.isEmpty) {
      err.writeln('username cannot be empty');
      return 64;
    }
    password ??= _promptSecret('Password: ');
    if (password.isEmpty) {
      err.writeln('password cannot be empty');
      return 64;
    }

    final res = await login(username, password);
    if (res.error) {
      err.writeln(res.errorMessage);
      return 1;
    }
    out.writeln('Logged in to ${source.key}');
    return 0;
  }

  Future<int> _loginWithCookies(
    ComicSource source,
    List<String> cookieArguments,
  ) async {
    final account = source.account;
    final loginWithCookies = account?.loginWithCookies;
    final fields = account?.cookieFields;
    if (loginWithCookies == null || fields == null || fields.isEmpty) {
      err.writeln('source ${source.key} does not support cookie login');
      return 1;
    }

    final provided = <String, String>{};
    for (final cookie in cookieArguments) {
      final index = cookie.indexOf('=');
      if (index <= 0) {
        err.writeln('--cookie must use field=value format');
        return 64;
      }
      provided[cookie.substring(0, index)] = cookie.substring(index + 1);
    }

    final values = <String>[];
    for (final field in fields) {
      var value = provided[field];
      value ??= _promptSecret('$field: ');
      if (value.isEmpty) {
        err.writeln('$field cannot be empty');
        return 64;
      }
      values.add(value);
    }

    final res = await loginWithCookies(values);
    if (res.error) {
      err.writeln(res.errorMessage);
      return 1;
    }
    out.writeln('Logged in to ${source.key}');
    return 0;
  }

  Future<int> _logout(ComicSource source) async {
    final account = source.account;
    if (account == null) {
      err.writeln('source ${source.key} does not support account login');
      return 1;
    }
    source.data.remove('account');
    source.data.remove('cookies');
    account.logout();
    await source.saveData();
    out.writeln('Logged out from ${source.key}');
    return 0;
  }

  Future<int> _search(ComicSource source, List<String> arguments) async {
    final parser = ArgParser()
      ..addOption('page', abbr: 'p', defaultsTo: '1')
      ..addMultiOption('option', abbr: 'o');
    final results = parser.parse(arguments);
    if (results.rest.length != 1) {
      err.writeln('Usage: venera ${source.key} search [--page n] <keyword>');
      err.writeln(parser.usage);
      return 64;
    }
    final search = source.searchPageData;
    if (search == null || search.loadPage == null) {
      err.writeln('source ${source.key} does not support search');
      return 1;
    }
    final page = int.tryParse(results.option('page') ?? '');
    if (page == null || page < 1) {
      err.writeln('--page must be a positive integer');
      return 64;
    }
    final options = results.multiOption('option').isEmpty
        ? _defaultSearchOptions(source)
        : results.multiOption('option');
    final res = await search.loadPage!(results.rest.single, page, options);
    return _printResult(
      res,
      (comics) => comics.map((e) => e.toJson()).toList(),
    );
  }

  Future<int> _info(ComicSource source, List<String> arguments) async {
    if (arguments.length != 1) {
      err.writeln('Usage: venera ${source.key} info <comic-id>');
      return 64;
    }
    if (source.loadComicInfo == null) {
      err.writeln('source ${source.key} does not support comic info');
      return 1;
    }
    final res = await source.loadComicInfo!(arguments.single);
    return _printResult(res, (details) => details.toJson());
  }

  Future<int> _pages(ComicSource source, List<String> arguments) async {
    final parser = ArgParser()..addOption('ep');
    final results = parser.parse(arguments);
    if (results.rest.length != 1) {
      err.writeln('Usage: venera ${source.key} pages [--ep id] <comic-id>');
      err.writeln(parser.usage);
      return 64;
    }
    if (source.loadComicPages == null) {
      err.writeln('source ${source.key} does not support comic pages');
      return 1;
    }
    final res = await source.loadComicPages!(
      results.rest.single,
      results.option('ep'),
    );
    return _printResult(res, (pages) => pages);
  }

  Future<int> _explore(ComicSource source, List<String> arguments) async {
    final parser = ArgParser()
      ..addOption('page', abbr: 'p', defaultsTo: '1')
      ..addOption('next');
    final results = parser.parse(arguments);
    if (results.rest.length > 1) {
      err.writeln('Usage: venera ${source.key} explore [index] [--page n]');
      err.writeln(parser.usage);
      return 64;
    }
    if (source.explorePages.isEmpty) {
      err.writeln('source ${source.key} does not support explore');
      return 1;
    }
    final index = results.rest.isEmpty
        ? 0
        : int.tryParse(results.rest.single) ??
              (throw const FormatException('explore index must be an integer'));
    if (index < 0 || index >= source.explorePages.length) {
      err.writeln('explore index out of range');
      return 64;
    }
    final explore = source.explorePages[index];
    if (explore.loadPage != null) {
      final page = int.tryParse(results.option('page') ?? '');
      if (page == null || page < 1) {
        err.writeln('--page must be a positive integer');
        return 64;
      }
      final res = await explore.loadPage!(page);
      return _printResult(
        res,
        (comics) => comics.map((e) => e.toJson()).toList(),
      );
    }
    if (explore.loadNext != null) {
      final res = await explore.loadNext!(results.option('next'));
      return _printResult(
        res,
        (comics) => comics.map((e) => e.toJson()).toList(),
      );
    }
    if (explore.loadMultiPart != null) {
      final res = await explore.loadMultiPart!();
      return _printResult(
        res,
        (parts) => parts
            .map(
              (part) => {
                'title': part.title,
                'comics': part.comics.map((e) => e.toJson()).toList(),
              },
            )
            .toList(),
      );
    }
    err.writeln('explore page $index is not supported by the CLI yet');
    return 1;
  }

  List<String> _defaultSearchOptions(ComicSource source) {
    return source.searchPageData?.searchOptions
            ?.map((option) => option.defaultValue)
            .toList() ??
        const [];
  }

  int _printResult<T>(Res<T> res, Object? Function(T data) encode) {
    if (res.error) {
      err.writeln(res.errorMessage);
      return 1;
    }
    out.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'data': encode(res.data),
        if (res.subData != null) 'subData': res.subData,
      }),
    );
    return 0;
  }

  bool _isUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  String _prompt(String label) {
    out.write(label);
    return input.readLineSync() ?? '';
  }

  String _promptSecret(String label) {
    out.write(label);
    if (!input.hasTerminal) {
      return input.readLineSync() ?? '';
    }
    final previousEchoMode = input.echoMode;
    try {
      input.echoMode = false;
      return input.readLineSync() ?? '';
    } finally {
      input.echoMode = previousEchoMode;
      out.writeln();
    }
  }

  void _ensureNoExtra(List<String> arguments, int expected, String usage) {
    if (arguments.length != expected) {
      throw FormatException('Usage: $usage');
    }
  }

  void _printUsage(ArgParser parser, {IOSink? sink}) {
    final target = sink ?? out;
    target.writeln('Usage: venera [options] <command>');
    target.writeln('');
    target.writeln(parser.usage);
    target.writeln('');
    target.writeln('Commands:');
    target.writeln('  source list');
    target.writeln('  source load [-f] <filepath/url>');
    target.writeln('  source update [key]');
    target.writeln('  source delete <key>');
    target.writeln('  <source-key> account');
    target.writeln('  <source-key> login [--username name] [--password pwd]');
    target.writeln('  <source-key> login --cookie field=value');
    target.writeln('  <source-key> logout');
    target.writeln('  <source-key> search [--page n] <keyword>');
    target.writeln('  <source-key> info <comic-id>');
    target.writeln('  <source-key> pages [--ep id] <comic-id>');
    target.writeln('  <source-key> explore [index]');
  }

  void _printSourceUsage() {
    out.writeln('Usage: venera source <command>');
    out.writeln('');
    out.writeln('Commands:');
    out.writeln('  list');
    out.writeln('  load [-f] <filepath/url>');
    out.writeln('  update [key]');
    out.writeln('  delete <key>');
  }

  void _printComicUsage() {
    out.writeln('Usage: venera <source-key> <command>');
    out.writeln('');
    out.writeln('Commands:');
    out.writeln('  account');
    out.writeln('  login [--username name] [--password pwd]');
    out.writeln('  login --cookie field=value');
    out.writeln('  logout');
    out.writeln('  search [--page n] <keyword>');
    out.writeln('  info <comic-id>');
    out.writeln('  pages [--ep id] <comic-id>');
    out.writeln('  explore [index]');
  }
}
