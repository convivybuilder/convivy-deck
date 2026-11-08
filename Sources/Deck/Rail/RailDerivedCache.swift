import Foundation

/// A single-slot memo: recomputes `Output` only when `Input` differs from
/// the last call, compared by `Equatable` — see CQ·196. `ContentView`'s
/// merged crew list (`CrewMerge.merge`), its discovered-session grouping
/// (`SessionGrouping.group`/`owningCrewId`), its per-ref parent maps, and
/// its per-row themes were all computed properties, re-run on every
/// access rather than once per change of their real inputs (configuration,
/// served crews, discovered sessions, hosts). Because
/// `RailStateModel.states` is one `@Published` dictionary covering every
/// polled session, a single session's poll result invalidated it and
/// re-ran every one of those computed properties for every row on the
/// rail on every render — measured by a 10s `xctrace` Time Profiler trace
/// at 7421 of 7732 main-thread samples, dominated by
/// `SessionGrouping`/`CrewMerge`/`Hasher`/`AnyKeyPath`.
///
/// A REFERENCE TYPE, NOT A STRUCT. `ContentView`/`RailView`/
/// `SessionsSettingsView` are `View` structs SwiftUI reconstructs on every
/// render; holding one of these in `@State` keeps the SAME instance across
/// those reconstructions, which is what lets it remember the last input at
/// all. Mutating a plain reference type's own stored properties from
/// inside a view's `body` never raises SwiftUI's "Publishing changes from
/// within view updates" diagnostic the way mutating an `@Published` or
/// `@State` VALUE from `body` would: this cache is observed by nothing, so
/// a hit or a miss is invisible to SwiftUI's own change tracking, and
/// recomputing on a miss is exactly as safe as the plain computed property
/// this replaces.
final class RailDerivedCache<Input: Equatable, Output> {
    private var lastInput: Input?
    private var lastOutput: Output?

    /// Called once per actual recompute, never on a cache hit — the seam a
    /// test counts to pin "same input, no recompute" and "changed input,
    /// one recompute" without needing to inspect `Output` itself.
    var onRecompute: () -> Void = {}

    func value(for input: Input, compute: () -> Output) -> Output {
        if let lastInput, lastInput == input, let lastOutput {
            return lastOutput
        }
        let output = compute()
        onRecompute()
        lastInput = input
        lastOutput = output
        return output
    }
}
