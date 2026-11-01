import Foundation
import CoreGraphics

extension CanvasModel {
    func workspaceChanged(_ size: CGSize) {
        workspaceSize = size
        guard !document.fixedCanvas, size.width > 0, size.height > 0 else { return }
        document.canvasWidth = size.width.rounded(); document.canvasHeight = size.height.rounded()
        if document.gridActive { arrange(recordHistory: false) }
    }
    func arrange(recordHistory: Bool = true) {
        if recordHistory && !canEdit { return }
        let movable = clips.filter { !$0.state.locked }; guard !movable.isEmpty else { return }
        let canvas = CGRect(x: 0, y: 0, width: document.canvasWidth, height: document.canvasHeight)
        let locks = clips.filter { $0.state.locked }.map { c in CGRect(x: c.state.x * canvas.width, y: c.state.y * canvas.height, width: c.state.width * canvas.width, height: c.state.height * canvas.height).intersection(canvas) }.filter { !$0.isNull }
        var regions = [canvas]
        for lock in locks {
            regions = regions.flatMap { area -> [CGRect] in
                guard area.intersects(lock) else { return [area] }
                return [CGRect(x: area.minX, y: area.minY, width: max(0, lock.minX - area.minX), height: area.height), CGRect(x: lock.maxX, y: area.minY, width: max(0, area.maxX - lock.maxX), height: area.height), CGRect(x: area.minX, y: area.minY, width: area.width, height: max(0, lock.minY - area.minY)), CGRect(x: area.minX, y: lock.maxY, width: area.width, height: max(0, area.maxY - lock.maxY))].filter { $0.width > 4 && $0.height > 4 }
            }.sorted { $0.width * $0.height > $1.width * $1.height }
            if regions.count > 128 { regions = Array(regions.prefix(128)) }
        }
        guard let region = regions.max(by: { $0.width * $0.height < $1.width * $1.height }), region.width > 8, region.height > 8 else { status = "Locked videos leave no space for a grid."; return }
        let gap = min(16.0, min(region.width, region.height) * 0.02)
        var best = -1.0; var bestGroups: [[Clip]] = []; var bestHeight = 0.0
        for rows in 1...movable.count {
            for _ in 0..<4 {
                let order = movable.shuffled(); var groups: [[Clip]] = []; var offset = 0
                for row in 0..<rows { let n = movable.count / rows + (row < movable.count % rows ? 1 : 0); groups.append(Array(order[offset..<(offset+n)])); offset += n }
                var height = (region.height - gap * Double(rows + 1)) / Double(rows)
                for group in groups { height = min(height, (region.width - gap * Double(group.count + 1)) / group.reduce(0) { $0 + $1.state.aspect }) }
                let area = height * height * movable.reduce(0) { $0 + $1.state.aspect }
                if height > 0 && area > best { best = area; bestGroups = groups; bestHeight = height }
            }
        }
        guard !bestGroups.isEmpty else { return }
        if recordHistory { checkpoint() }
        var y = region.minY + (region.height - bestHeight * Double(bestGroups.count) - gap * Double(bestGroups.count - 1)) / 2
        for group in bestGroups {
            let total = group.reduce(0) { $0 + $1.state.aspect * bestHeight } + gap * Double(group.count - 1)
            var x = region.minX + (region.width - total) / 2
            for clip in group {
                clip.state.x = x / canvas.width; clip.state.y = y / canvas.height
                clip.state.width = bestHeight * clip.state.aspect / canvas.width; clip.state.height = bestHeight / canvas.height
                x += bestHeight * clip.state.aspect + gap
            }; y += bestHeight + gap
        }
        document.gridActive = true
        if recordHistory { changed() }
    }
    func setCanvas(_ width: Double, _ height: Double) {
        guard canEdit, recording == nil else { return }; checkpoint()
        document.fixedCanvas = width > 0
        if width > 0 { document.canvasWidth = width; document.canvasHeight = height } else { document.canvasWidth = workspaceSize.width.rounded(); document.canvasHeight = workspaceSize.height.rounded() }
        arrange(recordHistory: false); changed()
    }
}
