import Foundation

enum WidgetGuidelineModule: String, CaseIterable {
    case art
    case mockup
    case interactive
    case chart
    case diagram
}

struct WidgetGuidelines {
    private enum Section: String {
        case svgSetup = "svg_setup"
        case artAndIllustration = "art_and_illustration"
        case uiComponents = "ui_components"
        case colorPalette = "color_palette"
        case chartsChartJs = "charts_chart_js"
        case diagramTypes = "diagram_types"
    }

    private static let moduleSections: [WidgetGuidelineModule: [Section]] = [
        .art: [.svgSetup, .artAndIllustration],
        .mockup: [.uiComponents, .colorPalette],
        .interactive: [.uiComponents, .colorPalette],
        .chart: [.uiComponents, .colorPalette, .chartsChartJs],
        .diagram: [.colorPalette, .svgSetup, .diagramTypes],
    ]

    private static var cache: [String: String] = [:]

    private static func loadSection(_ section: Section) -> String {
        if let cached = cache[section.rawValue] { return cached }
        guard let url = Bundle.main.url(forResource: section.rawValue, withExtension: "md") else {
            return ""
        }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        cache[section.rawValue] = content
        return content
    }

    private static func loadCore() -> String {
        if let cached = cache["core"] { return cached }
        guard let url = Bundle.main.url(forResource: "core", withExtension: "md") else {
            return ""
        }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        cache["core"] = content
        return content
    }

    static func getGuidelines(modules: [WidgetGuidelineModule]) -> String {
        var content = loadCore()
        var seen = Set<Section>()

        for module in modules {
            guard let sections = moduleSections[module] else { continue }
            for section in sections {
                if seen.contains(section) { continue }
                seen.insert(section)
                content += "\n\n\n" + loadSection(section)
            }
        }
        return content + "\n"
    }

    static var availableModules: [String] {
        WidgetGuidelineModule.allCases.map(\.rawValue)
    }
}
