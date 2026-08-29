import 'package:server_box/data/model/server/server_exec.dart';
import 'package:server_box/data/model/server/service.dart';
import 'package:server_box/data/service/service_manager.dart';

final class SystemdServiceManager implements ServiceManagerBackend {
  const SystemdServiceManager();

  @override
  ServiceManagerType get type => ServiceManagerType.systemd;

  @override
  Future<ServiceListing> list(ServerExec exec) async {
    final system = await _listScope(exec, ServiceScope.system);
    if (system.failed) throw ServiceManagerLoadException(system.raw);

    final user = await _listScope(exec, ServiceScope.user);
    final units = [...user.units, ...system.units]..sort(compareServices);
    return ServiceListing(
      units: units,
      notice: user.failed
          ? ServiceListingNotice.userScopeUnavailable
          : null,
      detail: user.failed ? user.raw : null,
    );
  }

  Future<({List<ServiceUnit> units, bool failed, String raw})> _listScope(
    ServerExec exec,
    ServiceScope scope,
  ) async {
    final result = await exec.run(listCommand(scope));
    final raw = result.combined;
    final units = parseListUnits(result.stdout, scope);
    final failed = !result.succeeded;
    if (failed || units.isEmpty) return (units: units, failed: failed, raw: raw);

    // Origins are a filtering nicety, not part of the listing: a host that
    // cannot report them still has a usable page, so a failure here leaves
    // every unit at its default rather than failing the scope.
    final origins = await exec.run(originCommand(scope, units));
    if (!origins.succeeded) return (units: units, failed: false, raw: raw);

    final paths = parseFragmentPaths(origins.stdout);
    final resolved = [
      for (final unit in units)
        unit.withOrigin(originOf(paths[unit.fullName], scope)),
    ];
    return (units: resolved, failed: false, raw: raw);
  }

  static String listCommand(ServiceScope scope) {
    final prefix = scope == ServiceScope.system
        ? 'systemctl'
        : 'systemctl --user';
    return '$prefix list-units --all --no-legend --no-pager --plain '
        '--type=service,socket,mount,timer';
  }

  /// Asks for the path of each unit already listed, rather than globbing.
  ///
  /// The names come from a listing the manager just produced, so they are
  /// exactly the units the page will show — no pattern to over- or under-match,
  /// and nothing fetched that is about to be discarded. `--` keeps a unit whose
  /// name begins with a dash from being read as an option.
  static String originCommand(ServiceScope scope, List<ServiceUnit> units) {
    final prefix = scope == ServiceScope.system
        ? 'systemctl'
        : 'systemctl --user';
    final names = units
        .map((unit) => quotedServiceName(unit.fullName))
        .join(' ');
    return '$prefix show --no-pager --property=Id --property=FragmentPath '
        '-- $names';
  }

  /// Parses `systemctl show --property=Id --property=FragmentPath` output.
  ///
  /// Units come back as blank-line separated blocks of `Key=Value`, but the
  /// order of properties within a block is systemd's, not the order they were
  /// asked for, so this keys off `Id=` rather than counting lines. A unit with
  /// no fragment file still reports `FragmentPath=` with an empty value, which
  /// is preserved: knowing a unit has no file is different from not knowing.
  static Map<String, String> parseFragmentPaths(String output) {
    final paths = <String, String>{};
    var id = '';
    var path = '';

    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        if (id.isNotEmpty) paths[id] = path;
        id = '';
        path = '';
        continue;
      }

      final idx = trimmed.indexOf('=');
      if (idx <= 0) continue;
      final key = trimmed.substring(0, idx);
      final value = trimmed.substring(idx + 1);

      if (key == 'Id') {
        // A blank line is what ends a block; a second `Id` only means one
        // ended without its separator, which systemd does not do but which
        // would otherwise merge two units. Resetting the path unconditionally
        // here would instead discard a `FragmentPath` that arrived before its
        // own `Id` — the very ordering this parser does not assume.
        if (id.isNotEmpty) {
          paths[id] = path;
          path = '';
        }
        id = value;
      } else if (key == 'FragmentPath') {
        path = value;
      }
    }
    if (id.isNotEmpty) paths[id] = path;
    return paths;
  }

  /// Classifies a `FragmentPath`.
  ///
  /// The user manager reads from `~/.config/systemd/user`, whose absolute form
  /// depends on the account, so that one is matched by suffix while the system
  /// locations are matched by prefix.
  static ServiceOrigin originOf(String? path, ServiceScope scope) {
    if (path == null || path.isEmpty) return ServiceOrigin.transient;
    if (path.startsWith('/etc/')) return ServiceOrigin.local;
    if (scope == ServiceScope.user && path.contains('/.config/systemd/')) {
      return ServiceOrigin.local;
    }
    if (path.startsWith('/run/')) return ServiceOrigin.runtime;
    if (path.startsWith('/lib/') || path.startsWith('/usr/lib/')) {
      return ServiceOrigin.vendor;
    }
    return ServiceOrigin.transient;
  }

  static List<ServiceUnit> parseListUnits(
    String output,
    ServiceScope scope,
  ) {
    final units = <ServiceUnit>[];
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 4) continue;

      final fullName = parts[0];
      final lastDot = fullName.lastIndexOf('.');
      if (lastDot <= 0) continue;

      final type = ServiceUnitType.fromString(fullName.substring(lastDot + 1));
      if (type == null) continue;

      final state = switch (parts[2].toLowerCase()) {
        'active' => ServiceState.running,
        'inactive' => ServiceState.stopped,
        'failed' => ServiceState.failed,
        'activating' => ServiceState.starting,
        'deactivating' => ServiceState.stopping,
        _ => null,
      };
      if (state == null) continue;

      units.add(ServiceUnit(
        name: fullName.substring(0, lastDot),
        type: type,
        scope: scope,
        state: state,
        actions: serviceActions(state),
        description: parts.length > 4 ? parts.sublist(4).join(' ') : null,
      ));
    }
    return units;
  }

  @override
  String commandFor(
    ServiceUnit unit,
    ServiceAction action, {
    required bool isRoot,
  }) {
    final prefix = unit.scope == ServiceScope.user
        ? 'systemctl --user'
        : isRoot
        ? 'systemctl'
        : 'sudo systemctl';
    final name = unit.fullName;
    return '$prefix ${action.name} ${quotedServiceName(name)}';
  }
}
