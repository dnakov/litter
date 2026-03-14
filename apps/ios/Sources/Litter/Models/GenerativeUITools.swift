import Foundation

enum GenerativeUITools {
    static let readMeToolName = "visualize_read_me"
    static let showWidgetToolName = "show_widget"

    static func buildDynamicToolSpecs() -> [DynamicToolSpec] {
        [readMeToolSpec(), showWidgetToolSpec()]
    }

    private static func readMeToolSpec() -> DynamicToolSpec {
        DynamicToolSpec(
            name: readMeToolName,
            description: """
                Returns design guidelines for show_widget (CSS patterns, colors, typography, layout rules, examples). \
                Call once before your first show_widget call. Do NOT mention this call to the user — it is an internal setup step. \
                Pick the modules that match your use case: interactive, chart, mockup, art, diagram.
                """,
            inputSchema: AnyEncodable(JSONSchema.object([
                "modules": .array(items: .stringEnum(
                    values: WidgetGuidelines.availableModules,
                    description: "Which module(s) to load. Pick all that fit."
                ))
            ], required: ["modules"]))
        )
    }

    private static func showWidgetToolSpec() -> DynamicToolSpec {
        DynamicToolSpec(
            name: showWidgetToolName,
            description: """
                Show visual content — SVG graphics, diagrams, charts, or interactive HTML widgets — rendered inline in the conversation. \
                Use for flowcharts, dashboards, forms, calculators, data tables, games, illustrations, or any visual content. \
                The HTML is rendered in a native WKWebView with full CSS/JS support including Canvas and CDN libraries. \
                IMPORTANT: Call visualize_read_me once before your first show_widget call. \
                Structure HTML as fragments: no DOCTYPE/<html>/<head>/<body>. Style first (<style> block under ~15 lines), then HTML content, then <script> tags last. \
                Scripts execute after streaming completes. Load libraries via <script src="https://cdnjs.cloudflare.com/ajax/libs/..."> (UMD globals). \
                CDN allowlist: cdnjs.cloudflare.com, esm.sh, cdn.jsdelivr.net, unpkg.com. \
                Dark mode is mandatory — use CSS variables for all colors. Background is transparent (host provides bg). \
                Keep widgets focused. Default size is 800x600 but adjust to fit content. \
                For SVG: start code with <svg> tag directly.
                """,
            inputSchema: AnyEncodable(JSONSchema.object([
                "i_have_seen_read_me": .boolean(description: "Confirm you have already called visualize_read_me in this conversation."),
                "title": .string(description: "Short snake_case identifier for this widget (used as widget title)."),
                "widget_code": .string(description: "HTML or SVG code to render. For SVG: raw SVG starting with <svg>. For HTML: raw content fragment, no DOCTYPE/<html>/<head>/<body>."),
                "width": .number(description: "Widget width in pixels. Default: 800."),
                "height": .number(description: "Widget height in pixels. Default: 600."),
            ], required: ["i_have_seen_read_me", "title", "widget_code"]))
        )
    }
}

// MARK: - JSON Schema Builder

indirect enum JSONSchema: Encodable {
    case object([String: JSONSchema], required: [String])
    case array(items: JSONSchema)
    case string(description: String? = nil)
    case stringEnum(values: [String], description: String? = nil)
    case number(description: String? = nil)
    case boolean(description: String? = nil)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SchemaKeys.self)
        switch self {
        case .object(let properties, let required):
            try container.encode("object", forKey: .type)
            try container.encode(properties, forKey: .properties)
            if !required.isEmpty {
                try container.encode(required, forKey: .required)
            }
        case .array(let items):
            try container.encode("array", forKey: .type)
            try container.encode(items, forKey: .items)
        case .string(let description):
            try container.encode("string", forKey: .type)
            if let description { try container.encode(description, forKey: .description) }
        case .stringEnum(let values, let description):
            try container.encode("string", forKey: .type)
            try container.encode(values, forKey: .enum_)
            if let description { try container.encode(description, forKey: .description) }
        case .number(let description):
            try container.encode("number", forKey: .type)
            if let description { try container.encode(description, forKey: .description) }
        case .boolean(let description):
            try container.encode("boolean", forKey: .type)
            if let description { try container.encode(description, forKey: .description) }
        }
    }

    private enum SchemaKeys: String, CodingKey {
        case type, properties, required, items, description
        case enum_ = "enum"
    }
}
