import 'package:flutter/foundation.dart';

/// One aircraft from a national register, in region-neutral terms.
///
/// `mark` is the registration as written ("C-FMHP", "N172SP"), `model` the type
/// designation, `common` the manufacturer or common name.
class RegisteredAircraft {
  final String mark;
  final String model;
  final String common;

  const RegisteredAircraft(this.mark, this.model, this.common);
}

/// Look up an aircraft by its Mode S address, or an address by its registration.
///
/// Traffic display and receiver configuration want to put a mark and a model on a
/// target, but nothing about that is region-specific: every authority publishes some
/// form of register. This interface is what the GDL90 and IO code depends on, so a
/// build with no register - or one for a different country - keeps working and simply
/// shows no mark.
///
/// Implementations must be cheap to call: these are hit per traffic message.
abstract class AircraftRegistry {
  /// The aircraft holding this Mode S address, or null if unknown.
  RegisteredAircraft? lookup(int icao);

  /// The Mode S address for a registration, or null if it cannot be determined.
  ///
  /// Some authorities allocate addresses by a formula, so an implementation may
  /// answer for marks that are not in its table.
  int? lookupIcao(String registration);

  /// How many entries are loaded. Zero is a legitimate answer.
  int get count;

  /// Bumped whenever the table changes, so views can rebuild.
  ValueNotifier<int> get change;
}

/// The default when no national register is installed: knows nothing, never fails.
class EmptyAircraftRegistry implements AircraftRegistry {
  @override
  final ValueNotifier<int> change = ValueNotifier<int>(0);

  EmptyAircraftRegistry();

  @override
  RegisteredAircraft? lookup(int icao) => null;

  @override
  int? lookupIcao(String registration) => null;

  @override
  int get count => 0;
}
