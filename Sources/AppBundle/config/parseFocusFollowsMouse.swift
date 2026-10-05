private let focusFollowsMouseParserTable: [String: any ParserProtocol<FocusFollowsMouse>] = [
    "enabled": Parser(\.enabled, parseBool),
    "floating-cover-percent": Parser(\.floatingCoverPercent, parsePercent),
]

private func parsePercent(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace)
        .flatMap { $0.takeIf { (0 ... 100).contains($0) }.toResult(.init(backtrace, "Must be in [0, 100] range")) }
}

func parseFocusFollowsMouse(_ rawConfig: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> FocusFollowsMouse {
    parseTable(rawConfig, FocusFollowsMouse(), focusFollowsMouseParserTable, backtrace, &c)
}
