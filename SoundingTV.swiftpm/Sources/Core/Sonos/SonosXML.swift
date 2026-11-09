import Foundation

struct SonosXMLElement: Sendable, Equatable {
    var name: String
    var attributes: [String: String]
    var children: [SonosXMLElement]
    var text: String

    var localName: String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func child(_ localName: String) -> SonosXMLElement? {
        children.first { $0.localName == localName }
    }

    func childText(_ localName: String) -> String? {
        child(localName)?.text
    }

    func first(_ localName: String) -> SonosXMLElement? {
        if self.localName == localName { return self }
        for child in children {
            if let found = child.first(localName) { return found }
        }
        return nil
    }

    func all(_ localName: String) -> [SonosXMLElement] {
        var result: [SonosXMLElement] = []
        collect(localName, into: &result)
        return result
    }

    private func collect(_ localName: String, into result: inout [SonosXMLElement]) {
        if self.localName == localName { result.append(self) }
        for child in children { child.collect(localName, into: &result) }
    }
}

enum SonosXML {
    static func parse(_ data: Data) throws -> SonosXMLElement {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let root = builder.root else {
            throw SonosResponseError.malformed(parser.parserError?.localizedDescription ?? "Unparseable XML")
        }
        return root
    }

    static func parse(_ string: String) throws -> SonosXMLElement {
        try parse(Data(string.utf8))
    }

    static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
        for character in string {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var stack: [SonosXMLElement] = []
        var root: SonosXMLElement?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            stack.append(SonosXMLElement(name: elementName, attributes: attributeDict, children: [], text: ""))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty, let string = String(data: CDATABlock, encoding: .utf8) else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let element = stack.popLast() else { return }
            if stack.isEmpty {
                root = element
            } else {
                stack[stack.count - 1].children.append(element)
            }
        }
    }
}
