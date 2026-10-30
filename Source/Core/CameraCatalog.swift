import Foundation

/// Image Capture can expose a populated media list with an empty folder tree.
/// Keep both views and parent links, without storing any original image bytes.
struct CameraCatalogItem {
    let id: String
    let folder: Bool
    let name: String?
    var originalName: String? = nil
    var size: Int64 = 0
    var parent: String? = nil
    var children: [String] = []
    var handle: UInt32 = 0
}

enum CameraCatalog {
    static func collect(hierarchy: [String], media: [String], items: [String: CameraCatalogItem]) throws -> [CameraObject] {
        var files: [String] = [], listed = Set<String>(), visited = Set<String>()
        var inferredParents: [String: String] = [:]
        func item(_ id: String) throws -> CameraCatalogItem {
            guard let item = items[id] else { throw ImportError("The camera returned an incomplete file catalog. Scan again.") }
            return item
        }
        func walk(_ id: String, ancestors: Set<String>) throws {
            guard ancestors.count < 64, !ancestors.contains(id) else { throw ImportError("The camera folder hierarchy is invalid.") }
            guard visited.insert(id).inserted else { return }
            let node = try item(id)
            if node.folder {
                for child in node.children {
                    if let parent = inferredParents[child], parent != id { throw ImportError("The camera returned ambiguous folder relationships.") }
                    inferredParents[child] = id
                    try walk(child, ancestors: ancestors.union([id]))
                }
            } else if listed.insert(id).inserted { files.append(id) }
        }
        for id in hierarchy { try walk(id, ancestors: []) }
        // Merge rather than substitute: the tree may expose sidecars omitted by
        // mediaFiles, while USB cameras such as Z 8 may expose only mediaFiles.
        for id in media {
            let node = try item(id)
            if !node.folder, listed.insert(id).inserted { files.append(id) }
        }
        var folderIDs: [String: String] = [:]
        var result: [CameraObject] = []
        for id in files {
            let file = try item(id)
            guard let name = file.name else { throw ImportError("The camera returned an original without a filename.") }
            guard MediaTypes.importable.contains((name as NSString).pathExtension.lowercased()) else { continue }
            if let original = file.originalName, !original.isEmpty, original != name {
                throw ImportError("The camera offered a converted file instead of its original. Use a card reader for this source.")
            }
            var path: [String] = [], originalPath: [String] = [], seen: Set<String> = [id]
            var parent = file.parent ?? inferredParents[id]
            while let key = parent {
                guard seen.count < 64, seen.insert(key).inserted else { throw ImportError("The camera folder hierarchy is invalid.") }
                let folder = try item(key)
                guard folder.folder else { throw ImportError("The camera returned an invalid parent folder.") }
                if folderIDs[key] == nil { folderIDs[key] = "folder-\(folderIDs.count + 1)" }
                path.insert(folderIDs[key]!, at: 0)
                originalPath.insert(folder.name ?? folderIDs[key]!, at: 0)
                parent = folder.parent ?? inferredParents[key]
            }
            result.append(CameraObject(id: id, folders: path, name: name, size: file.size,
                originalPath: (originalPath + [name]).joined(separator: "/") + "?object=\(file.handle)"))
        }
        return result
    }
}
