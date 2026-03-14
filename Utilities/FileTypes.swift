import UniformTypeIdentifiers

extension UTType {
    static var epub: UTType {
        UTType(importedAs: "org.idpf.epub-container")
    }

    static var markdown: UTType {
        UTType(importedAs: "net.daringfireball.markdown")
    }
}
