import AppKit

/// The thumbnail grid: sections, tiles, selection and filters.
extension MainWindowController {
    func entries() -> [(String, String, [GridEntry])] {
        if let plan {
            let visible = plan.groups.filter { group in
                let members = plan.members(group)
                if case .some(let day) = dateFilter, group.date != day { return false }
                if !typeFilter.matches(members.map(\.source)) { return false }
                if showImported.state == .off && !(group.isNew || group.status == .sidecarChanged) { return false }
                return true
            }
            var displayedDates: [CaptureDay: String] = [:]
            func dateLabel(_ day: CaptureDay) -> String {
                if let cached = displayedDates[day] { return cached }
                let text = Self.display(day); displayedDates[day] = text; return text
            }
            func entry(_ group: PhotoGroup) -> GridEntry {
                let members = plan.members(group)
                let primaries = members.filter { $0.role != .sidecar }
                let sidecars = members.filter { $0.role == .sidecar }.map { $0.source.pathExtension.uppercased() }
                let kinds = primaries.map { $0.source.pathExtension.uppercased() }.joined(separator: " + ") + (sidecars.isEmpty ? "" : " · " + sidecars.joined(separator: " "))
                let date = group.date.map(dateLabel) ?? "No capture date"
                let files = members.count == 1 ? "1 file" : "\(members.count) files"
                let destination = group.folder.map { "\(plan.root.lastPathComponent)/\($0)/" }
                let thumbnail = primaries.first { $0.role == .image }?.source ?? primaries[0].source
                return GridEntry(
                    id: group.id, name: group.name, thumbnail: thumbnail, kinds: kinds, fileCount: members.count,
                    detail: "\(date) · \(files)", status: group.status, missingDate: plan.missingDates(in: [group.id]) > 0, destination: destination,
                    dateOrigin: group.date == nil ? nil : group.dateOrigin, cachedVerification: members.contains(where: \.cachedVerification), otherCard: members.contains(where: \.otherCardCopy))
            }
            let fresh = visible.filter(\.isNew).map(entry)
            let other = visible.filter { !$0.isNew }.map(entry)
            var result: [(String, String, [GridEntry])] = []
            if !fresh.isEmpty { result.append(("New Photos", "\(fresh.count) \(fresh.count == 1 ? "photo" : "photos")", fresh)) }
            if !other.isEmpty { result.append(("Already Imported", "\(other.count)", other)) }
            return result
        }
        if let preliminary {
            let items = preliminary.enumerated().map { index, group in
                GridEntry(
                    id: index, name: group.primaries[0].deletingPathExtension().lastPathComponent,
                    thumbnail: group.primaries.first { MediaTypes.role(of: $0) == .image } ?? group.primaries[0],
                    kinds: group.primaries.map { $0.pathExtension.uppercased() }.joined(separator: " + ") + (group.sidecars.isEmpty ? "" : " · +\(group.sidecars.count)"),
                    fileCount: group.members.count, detail: "Checking…", status: nil, missingDate: false, destination: nil)
            }
            return [("Scanning", "\(items.count) photos found", items)]
        }
        return []
    }

    static func display(_ day: CaptureDay) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? Date()
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].entries.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GroupTileItem.identifier, for: indexPath) as! GroupTileItem
        let entry = sections[indexPath.section].entries[indexPath.item]
        item.tile.configure(entry, checked: plan != nil && selection.contains(entry.id))
        item.tile.onToggle = { [weak self] flags in self?.toggle(entry.id, flags) }
        let key = ThumbnailLoader.key(entry.thumbnail)
        if let image = thumbnails.cached(key) {
            item.tile.setImage(image, placeholder: false)
        } else {
            item.tile.setImage(nil, placeholder: true)
            if !thumbnails.hasFailed(key) {
                item.operation = thumbnails.load(entry.thumbnail, key: key) { [weak item] image in
                    guard let item, item.tile.entry?.thumbnail == entry.thumbnail else { return }
                    item.tile.setImage(image, placeholder: image == nil)
                }
            }
        }
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        // Cancel thumbnail work for tiles scrolled out of view.
        (item as? GroupTileItem)?.operation?.cancel()
    }
    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeader.identifier, for: indexPath) as! SectionHeader
        header.title.stringValue = sections[indexPath.section].title
        header.detail.stringValue = sections[indexPath.section].detail
        return header
    }
    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        NSSize(width: tileWidth, height: tileWidth * 0.75 + 38)
    }

    var visibleIDs: [Int] { sections.flatMap { $0.entries.filter(\.selectable).map(\.id) } }

    func toggle(_ id: Int, _ flags: NSEvent.ModifierFlags) {
        guard let plan, state == .idle, plan.groups.indices.contains(id) else { return }
        let order = visibleIDs
        if flags.contains(.shift), let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            let range = order[min(from, to)...max(from, to)]
            if selection.contains(anchor) { selection.formUnion(range) } else { selection.subtract(range) }
        } else {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        }
        updateTiles(); updateFooter()
    }
    func updateTiles() {
        for item in collection.visibleItems() {
            guard let tile = (item as? GroupTileItem)?.tile, let entry = tile.entry else { continue }
            tile.configure(entry, checked: plan != nil && selection.contains(entry.id))
        }
    }

    @objc func selectAllNew(_ sender: Any?) {
        guard let plan, state == .idle else { return }
        selection = Set(visibleIDs).intersection(plan.importableNewGroups); anchor = nil
        updateTiles(); updateFooter()
    }
    @objc func deselectAll(_ sender: Any?) {
        guard state == .idle else { return }
        selection = []; anchor = nil; updateTiles(); updateFooter()
    }
    @objc override func selectAll(_ sender: Any?) {
        guard plan != nil, state == .idle else { return }
        selection = Set(visibleIDs); anchor = nil; updateTiles(); updateFooter()
    }

    @objc func filtersChanged() {
        typeFilter = TypeFilter(rawValue: typePopup.indexOfSelectedItem) ?? .all
        let index = datePopup.indexOfSelectedItem
        dateFilter = index > 0 && index <= dateOptions.count ? .some(dateOptions[index - 1]) : nil
        refresh()
    }
    @objc func resizeTiles() { tileWidth = CGFloat(sizeSlider.doubleValue); collection.collectionViewLayout?.invalidateLayout() }
    func zoom(by delta: CGFloat) { sizeSlider.doubleValue = Double(min(300, max(110, tileWidth + delta))); resizeTiles() }

    func rebuildDateFilter() {
        datePopup.removeAllItems(); dateOptions = []
        datePopup.addItem(withTitle: "All Dates")
        if let plan {
            var counts: [CaptureDay?: Int] = [:]
            for group in plan.groups { counts[group.date, default: 0] += 1 }
            for day in counts.keys.compactMap({ $0 }).sorted() {
                datePopup.addItem(withTitle: "\(Self.display(day))  (\(counts[day]!))"); dateOptions.append(day)
            }
            if let missing = counts[nil] { datePopup.addItem(withTitle: "No Capture Date  (\(missing))"); dateOptions.append(nil) }
        }
        if let current = dateFilter, let index = dateOptions.firstIndex(where: { $0 == current }) { datePopup.selectItem(at: index + 1) } else { dateFilter = nil; datePopup.selectItem(at: 0) }
    }
}
