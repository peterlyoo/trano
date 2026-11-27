import Foundation

public enum TerminalTitlePolicy {
    public static func generatedTitle(program: TerminalProgram, directory: String) -> String {
        let component = directory.isEmpty ? "" : URL(fileURLWithPath: directory).lastPathComponent
        return program.commandName + (component.isEmpty ? "" : " · " + component)
    }

    public static func displayTitle(manualTitle: String? = nil, generatedTitle: String?,
                                    terminalTitle: String?, fallbackTitle: String,
                                    preferGeneratedTitles: Bool) -> String {
        if let manual = TerminalTitleMetadata.normalize(manualTitle) { return manual }
        if preferGeneratedTitles, let generated = TerminalTitleMetadata.normalize(generatedTitle) { return generated }
        return TerminalTitleMetadata.normalize(terminalTitle) ?? TerminalTitleMetadata.normalize(fallbackTitle) ?? "Terminal"
    }
}

extension TerminalSession {
    public func displayTitle(preferGeneratedTitles: Bool) -> String {
        guard preferGeneratedTitles else { return displayTitle }
        return TerminalTitlePolicy.displayTitle(generatedTitle: TerminalTitlePolicy.generatedTitle(program: displayProgram, directory: cwd),
                                                terminalTitle: terminalTitle, fallbackTitle: title,
                                                preferGeneratedTitles: preferGeneratedTitles)
    }
}
