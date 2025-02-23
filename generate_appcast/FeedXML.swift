//
//  Created by Kornel on 22/12/2016.
//  Copyright © 2016 Sparkle Project. All rights reserved.
//

import Foundation

let maxVersionsInFeed = 5

func findElement(name: String, parent: XMLElement) -> XMLElement? {
    if let found = try? parent.nodes(forXPath: name) {
        if found.count > 0 {
            if let element = found[0] as? XMLElement {
                return element
            }
        }
    }
    return nil
}

func findOrCreateElement(name: String, parent: XMLElement) -> XMLElement {
    if let element = findElement(name: name, parent: parent) {
        return element
    }
    let element = XMLElement(name: name)
    parent.addChild(element)
    return element
}

func text(_ text: String) -> XMLNode {
    return XMLNode.text(withStringValue: text) as! XMLNode
}

func writeAppcast(appcastDestPath: URL, updates: [ArchiveItem]) throws {
    let appBaseName = updates[0].appPath.deletingPathExtension().lastPathComponent

    let sparkleNS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

    var doc: XMLDocument
    do {
        let options: XMLNode.Options = [
            XMLNode.Options.nodeLoadExternalEntitiesNever,
            XMLNode.Options.nodePreserveCDATA,
            XMLNode.Options.nodePreserveWhitespace
        ]
        doc = try XMLDocument(contentsOf: appcastDestPath, options: options)
    } catch {
        let root = XMLElement(name: "rss")
        root.addAttribute(XMLNode.attribute(withName: "xmlns:sparkle", stringValue: sparkleNS) as! XMLNode)
        root.addAttribute(XMLNode.attribute(withName: "version", stringValue: "2.0") as! XMLNode)
        doc = XMLDocument(rootElement: root)
        doc.isStandalone = true
    }

    var channel: XMLElement

    let rootNodes = try doc.nodes(forXPath: "/rss")
    if rootNodes.count != 1 {
        throw makeError(code: .appcastError, "Weird XML? \(appcastDestPath.path)")
    }
    let root = rootNodes[0] as! XMLElement
    let channelNodes = try root.nodes(forXPath: "channel")
    if channelNodes.count > 0 {
        channel = channelNodes[0] as! XMLElement
    } else {
        channel = XMLElement(name: "channel")
        channel.addChild(XMLElement.element(withName: "title", stringValue: appBaseName) as! XMLElement)
        root.addChild(channel)
    }

    var numItems = 0
    for update in updates {
        var item: XMLElement
        let existingItems = try channel.nodes(forXPath: "item[enclosure[@sparkle:version=\"\(update.version)\"]]")
        let createNewItem = existingItems.count == 0

        // Update all old items, but aim for less than 5 in new feeds
        if createNewItem && numItems >= maxVersionsInFeed {
            continue
        }
        numItems += 1

        if createNewItem {
            item = XMLElement.element(withName: "item") as! XMLElement
            channel.addChild(item)
        } else {
            item = existingItems[0] as! XMLElement
        }

        if nil == findElement(name: "title", parent: item) {
            item.addChild(XMLElement.element(withName: "title", stringValue: update.shortVersion) as! XMLElement)
        }
        if nil == findElement(name: "pubDate", parent: item) {
            item.addChild(XMLElement.element(withName: "pubDate", stringValue: update.pubDate) as! XMLElement)
        }

        if let html = update.releaseNotesHTML {
            let descElement = findOrCreateElement(name: "description", parent: item)
            let cdata = XMLNode(kind: .text, options: .nodeIsCDATA)
            cdata.stringValue = html
            descElement.setChildren([cdata])
        }

        var minVer = findElement(name: SUAppcastElementMinimumSystemVersion, parent: item)
        if nil == minVer {
            minVer = XMLElement.element(withName: SUAppcastElementMinimumSystemVersion, uri: sparkleNS) as? XMLElement
            item.addChild(minVer!)
        }
        minVer?.setChildren([text(update.minimumSystemVersion)])

        // Look for an existing release notes element
        let releaseNotesXpath = "\(SUAppcastElementReleaseNotesLink)"
        let results = ((try? item.nodes(forXPath: releaseNotesXpath)) as? [XMLElement])?
            .filter { !($0.attributes ?? [])
            .contains(where: { $0.name == SUXMLLanguage }) }
        let relElement = results?.first

        if let url = update.releaseNotesURL {
            // The update includes a valid release notes URL
            if let existingReleaseNotesElement = relElement {
                // The existing item includes a release notes element. Update it.
                existingReleaseNotesElement.stringValue = url.absoluteString
            } else {
                // The existing item doesn't have a release notes element. Add one.
                item.addChild(XMLElement.element(withName: SUAppcastElementReleaseNotesLink, stringValue: url.absoluteString) as! XMLElement)
            }
        } else if let childIndex = relElement?.index {
            // The update doesn't include a release notes URL. Remove it.
            item.removeChild(at: childIndex)
        }

        let languageNotesNodes = ((try? item.nodes(forXPath: releaseNotesXpath)) as? [XMLElement])?
            .map { ($0, $0.attribute(forName: SUXMLLanguage)?.stringValue )}
            .filter { $0.1 != nil } ?? []
        for (node, language) in languageNotesNodes.reversed()
            where !update.localizedReleaseNotes().contains(where: { $0.0 == language }) {
            item.removeChild(at: node.index)
        }
        for (language, url) in update.localizedReleaseNotes() {
            if !languageNotesNodes.contains(where: { $0.1 == language }) {
                let localizedNode = XMLNode.element(
                    withName: SUAppcastElementReleaseNotesLink,
                    children: [XMLNode.text(withStringValue: url.absoluteString) as! XMLNode],
                    attributes: [XMLNode.attribute(withName: SUXMLLanguage, stringValue: language) as! XMLNode])
                item.addChild(localizedNode as! XMLNode)
            }
        }

        var enclosure = findElement(name: "enclosure", parent: item)
        if nil == enclosure {
            enclosure = XMLElement.element(withName: "enclosure") as? XMLElement
            item.addChild(enclosure!)
        }

        guard let archiveURL = update.archiveURL?.absoluteString else {
            throw makeError(code: .appcastError, "Bad archive name or feed URL")
        }
        var attributes = [
            XMLNode.attribute(withName: "url", stringValue: archiveURL) as! XMLNode,
            XMLNode.attribute(withName: SUAppcastAttributeVersion, uri: sparkleNS, stringValue: update.version) as! XMLNode,
            XMLNode.attribute(withName: SUAppcastAttributeShortVersionString, uri: sparkleNS, stringValue: update.shortVersion) as! XMLNode,
            XMLNode.attribute(withName: "length", stringValue: String(update.fileSize)) as! XMLNode,
            XMLNode.attribute(withName: "type", stringValue: update.mimeType) as! XMLNode
        ]
        if let sig = update.edSignature {
            attributes.append(XMLNode.attribute(withName: SUAppcastAttributeEDSignature, uri: sparkleNS, stringValue: sig) as! XMLNode)
        }
        if let sig = update.dsaSignature {
            attributes.append(XMLNode.attribute(withName: SUAppcastAttributeDSASignature, uri: sparkleNS, stringValue: sig) as! XMLNode)
        }
        enclosure!.attributes = attributes

        if update.deltas.count > 0 {
            var deltas = findElement(name: SUAppcastElementDeltas, parent: item)
            if nil == deltas {
                deltas = XMLElement.element(withName: SUAppcastElementDeltas, uri: sparkleNS) as? XMLElement
                item.addChild(deltas!)
            } else {
                deltas!.setChildren([])
            }
            for delta in update.deltas {
                var attributes = [
                    XMLNode.attribute(withName: "url", stringValue: URL(string: delta.archivePath.lastPathComponent.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed)!, relativeTo: update.archiveURL)!.absoluteString) as! XMLNode,
                    XMLNode.attribute(withName: SUAppcastAttributeVersion, uri: sparkleNS, stringValue: update.version) as! XMLNode,
                    XMLNode.attribute(withName: SUAppcastAttributeShortVersionString, uri: sparkleNS, stringValue: update.shortVersion) as! XMLNode,
                    XMLNode.attribute(withName: SUAppcastAttributeDeltaFrom, uri: sparkleNS, stringValue: delta.fromVersion) as! XMLNode,
                    XMLNode.attribute(withName: "length", stringValue: String(delta.fileSize)) as! XMLNode,
                    XMLNode.attribute(withName: "type", stringValue: "application/octet-stream") as! XMLNode
                    ]
                if let sig = delta.edSignature {
                    attributes.append(XMLNode.attribute(withName: SUAppcastAttributeEDSignature, uri: sparkleNS, stringValue: sig) as! XMLNode)
                }
                if let sig = delta.dsaSignature {
                    attributes.append(XMLNode.attribute(withName: SUAppcastAttributeDSASignature, uri: sparkleNS, stringValue: sig) as! XMLNode)
                }
                deltas!.addChild(XMLNode.element(withName: "enclosure", children: nil, attributes: attributes) as! XMLElement)
            }
        }
    }

    let options: XMLNode.Options = [.nodeCompactEmptyElement, .nodePrettyPrint]
    let docData = doc.xmlData(options: options)
    _ = try XMLDocument(data: docData, options: XMLNode.Options()); // Verify that it was generated correctly, which does not always happen!
    try docData.write(to: appcastDestPath)
}
