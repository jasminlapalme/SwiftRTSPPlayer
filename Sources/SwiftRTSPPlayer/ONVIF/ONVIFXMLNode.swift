//
//  ONVIFXMLNode.swift
//  SwiftRTSPPlayer
//

import Foundation

/// Minimal DOM built on Foundation's `XMLParser`, just enough to pull values
/// out of ONVIF SOAP responses without a third-party XML dependency.
/// Namespaces are processed so element names are local names ("Envelope",
/// not "s:Envelope").
final class ONVIFXMLNode {
	let name: String
	let attributes: [String: String]
	fileprivate(set) var text = ""
	fileprivate(set) var children: [ONVIFXMLNode] = []

	fileprivate init(name: String, attributes: [String: String]) {
		self.name = name
		self.attributes = attributes
	}

	/// First direct child with the given local name.
	subscript(name: String) -> ONVIFXMLNode? {
		children.first { $0.name == name }
	}

	/// All nodes (self included) with the given local name, depth-first.
	func descendants(named name: String) -> [ONVIFXMLNode] {
		var result: [ONVIFXMLNode] = self.name == name ? [self] : []
		for child in children {
			result.append(contentsOf: child.descendants(named: name))
		}
		return result
	}

	/// Parse an XML document and return its root element, or nil on malformed input.
	static func parse(_ data: Data) -> ONVIFXMLNode? {
		let builder = TreeBuilder()
		let parser = XMLParser(data: data)
		parser.delegate = builder
		parser.shouldProcessNamespaces = true
		guard parser.parse() else { return nil }
		return builder.root
	}
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
	var root: ONVIFXMLNode?
	private var stack: [ONVIFXMLNode] = []

	func parser(
		_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
		qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
	) {
		let node = ONVIFXMLNode(name: elementName, attributes: attributeDict)
		if let parent = stack.last {
			parent.children.append(node)
		} else {
			root = node
		}
		stack.append(node)
	}

	func parser(
		_ parser: XMLParser, didEndElement elementName: String,
		namespaceURI: String?, qualifiedName qName: String?
	) {
		if let node = stack.popLast() {
			node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
		}
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		stack.last?.text += string
	}
}
