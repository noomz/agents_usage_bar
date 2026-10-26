import AppKit
import UniformTypeIdentifiers

/// The formats Export… offers: the `aub stats --json` and `--csv <table>` outputs (V47–V49).
enum DashboardExportFormat: Hashable, CaseIterable {
    case json
    case csv(HistoryExportRenderer.CSVTable)

    static var allCases: [Self] {
        [.json] + HistoryExportRenderer.CSVTable.allCases.map(Self.csv)
    }

    var title: String {
        switch self {
        case .json: return "JSON"
        case .csv(let table): return "CSV — \(table.rawValue)"
        }
    }

    var contentType: UTType {
        switch self {
        case .json: return .json
        case .csv: return .commaSeparatedText
        }
    }

    /// `aub-usage-2026-10-01_2026-10-14.json`, or `…-events.csv` for a CSV table.
    func fileName(_ range: StatsRange) -> String {
        let span = "aub-usage-\(range.keys[0])_\(range.keys[range.keys.count - 1])"
        switch self {
        case .json: return span + ".json"
        case .csv(let table): return span + "-\(table.rawValue).csv"
        }
    }
}

/// Export… (SPEC V57): a save panel with a format picker, attached to the dashboard window.
/// The model renders the bytes; this only asks where to write them.
@MainActor
enum DashboardExporter {
    static func run(
        model: DashboardModel,
        window: NSWindow,
        isEnabled: @escaping @Sendable (ProviderID) -> Bool
    ) {
        let range = model.exportScope(isEnabled: isEnabled).range
        let panel = NSSavePanel()
        panel.title = "Export Usage History"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let formats = DashboardExportFormat.allCases
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: formats.map(\.title))
        let picker = FormatPicker(panel: panel, popup: popup, formats: formats, range: range)
        popup.target = picker
        popup.action = #selector(FormatPicker.changed)
        panel.accessoryView = accessory(popup)
        picker.apply()

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let format = picker.selected
            do {
                let text = try model.export(format, isEnabled: isEnabled, exportedAt: Date())
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private static func accessory(_ popup: NSPopUpButton) -> NSView {
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        return stack
    }

    /// Keeps the panel's file type in step with the popup, and the suggested name while the
    /// user has not typed their own.
    @MainActor
    private final class FormatPicker: NSObject {
        let panel: NSSavePanel
        let popup: NSPopUpButton
        let formats: [DashboardExportFormat]
        let range: StatsRange
        private var suggested: String?

        init(panel: NSSavePanel, popup: NSPopUpButton, formats: [DashboardExportFormat], range: StatsRange) {
            self.panel = panel
            self.popup = popup
            self.formats = formats
            self.range = range
        }

        var selected: DashboardExportFormat { formats[max(popup.indexOfSelectedItem, 0)] }

        @objc func changed() { apply() }

        func apply() {
            panel.allowedContentTypes = [selected.contentType]
            if suggested == nil || panel.nameFieldStringValue == suggested {
                suggested = selected.fileName(range)
                panel.nameFieldStringValue = suggested ?? ""
            }
        }
    }
}
