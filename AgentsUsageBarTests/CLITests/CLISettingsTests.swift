import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("CLISettings")
struct CLISettingsTests {

    private func make() -> (CLISettings, UserDefaults) {
        let suite = "test.aub.cli.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (CLISettings(defaults: defaults, customEngines: { [ProviderID(rawValue: "engine.gpu-box")] }), defaults)
    }

    @Test("defaults when keys are absent")
    func absentDefaults() {
        let (store, _) = make()
        #expect(try! store.get("refresh-interval").get().value == "5m")
        #expect(try! store.get("threshold").get().value == "0.80")
        #expect(try! store.get("theme").get().value == "auto")
        #expect(try! store.get("pace-warnings").get().value == "true")
        #expect(try! store.get("reset-notifications").get().value == "true")
        #expect(try! store.get("claude-source").get().value == "sessionReads")
        #expect(try! store.get("provider.claude.enabled").get().value == "true")
    }

    @Test("round-trip interval theme bool source")
    func roundTrip() {
        let (store, _) = make()
        #expect(try! store.set("refresh-interval", value: "1m").get().value == "1m")
        #expect(try! store.get("refresh-interval").get().value == "1m")
        #expect(try! store.set("theme", value: "dark").get().value == "dark")
        #expect(try! store.set("pace-warnings", value: "no").get().value == "false")
        #expect(try! store.set("reset-notifications", value: "no").get().value == "false")
        #expect(try! store.set("claude-source", value: "hook").get().value == "hook")
        #expect(try! store.set("provider.openrouter.enabled", value: "0").get().value == "false")
    }

    @Test("threshold range")
    func thresholdRange() {
        let (store, _) = make()
        #expect(try! store.set("threshold", value: "0.70").get().value == "0.70")
        switch store.set("threshold", value: "0.40") {
        case .failure(.invalidValue): break
        default: Issue.record("expected invalidValue for 0.40")
        }
        switch store.set("threshold", value: "1.2") {
        case .failure(.invalidValue): break
        default: Issue.record("expected invalidValue for 1.2")
        }
    }

    @Test("unknown key")
    func unknownKey() {
        let (store, _) = make()
        switch store.get("nope") {
        case .failure(.unknownKey("nope")): break
        default: Issue.record("expected unknownKey")
        }
    }

    @Test("open-at-login warns")
    func openAtLoginWarns() {
        let (store, _) = make()
        let result = try! store.set("open-at-login", value: "true").get()
        #expect(result.value == "true")
        #expect(result.warning != nil)
    }

    @Test("list includes every provider enabled key")
    func listProviders() {
        let (store, _) = make()
        let keys = Set(store.list().map(\.key))
        for id in ProviderID.allKnown {
            #expect(keys.contains("provider.\(id.rawValue).enabled"))
        }
    }

    @Test("cli-theme default, case-fold, validation, garbage fallback")
    func cliTheme() {
        let (store, defaults) = make()
        #expect(try! store.get("cli-theme").get().value == "compact")
        #expect(store.storedCLITheme == nil)
        #expect(try! store.set("cli-theme", value: "Classic").get().value == "classic")
        #expect(defaults.string(forKey: AUBDefaultsKey.cliTheme) == "classic")
        #expect(try! store.get("cli-theme").get().value == "classic")
        #expect(store.storedCLITheme == .classic)
        let bad = store.set("cli-theme", value: "fancy")
        #expect(bad == .failure(.invalidValue(key: "cli-theme", value: "fancy", expected: "compact|classic")))
        if case .failure(let err) = bad {
            #expect(err.description == "invalid value 'fancy' for cli-theme; expected compact|classic")
        }
        defaults.set("garbage", forKey: AUBDefaultsKey.cliTheme)
        #expect(try! store.get("cli-theme").get().value == "compact")
        #expect(store.storedCLITheme == nil)
    }

    @Test("provider-order default, validation, case-fold, reset")
    func providerOrder() {
        let (store, defaults) = make()
        let all = ProviderID.allKnown.map(\.rawValue).joined(separator: ",")
        #expect(try! store.get("provider-order").get().value == all)
        #expect(try! store.set("provider-order", value: "Codex, engine.gpu-box,claude").get().value
                == "codex,engine.gpu-box,claude")
        #expect(defaults.aubProviderOrder == [.codex, ProviderID(rawValue: "engine.gpu-box"), .claude])
        #expect(try! store.get("provider-order").get().value == "codex,engine.gpu-box,claude")
        for bad in ["codex,nope", "codex,Codex", "engine.unknown", "codex,,claude"] {
            switch store.set("provider-order", value: bad) {
            case .failure(.invalidValue(key: "provider-order", value: bad, let expected)):
                #expect(expected.contains("openrouter, claude"))
                #expect(expected.contains("engine.gpu-box"))
            default: Issue.record("expected invalidValue for \(bad)")
            }
        }
        #expect(defaults.string(forKey: AUBDefaultsKey.providerOrder) == "codex,engine.gpu-box,claude")
        #expect(try! store.set("provider-order", value: "").get().value == all)
        #expect(defaults.object(forKey: AUBDefaultsKey.providerOrder) == nil)
    }
}
