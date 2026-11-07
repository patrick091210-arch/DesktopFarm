import Foundation

/// Market, shipping bin, order board, automation, offline settlement.
extension GameEngine {
    // MARK: - Market

    func canBuy(_ product: ShopProduct) -> Bool {
        if case .upgrade(let upgrade) = product, game.hasUpgrade(upgrade) { return false }
        return game.level >= product.unlockLevel && game.coins >= product.price
    }

    @discardableResult
    func buy(_ product: ShopProduct, now: Date = Date()) -> Bool {
        guard game.level >= product.unlockLevel else {
            report("需要 Lv.\(product.unlockLevel) 才能购买\(product.displayName)")
            return false
        }
        if case .upgrade(let upgrade) = product, game.hasUpgrade(upgrade) {
            report("已经拥有\(upgrade.displayName)")
            return false
        }
        guard game.coins >= product.price else {
            report("金币不足：\(product.displayName)需要 \(product.price) 金币")
            return false
        }
        do {
            switch product {
            case .seed(let species):
                let payload = GameFilePayload(kind: .seed, itemType: species.rawValue, displayName: "\(species.displayName)种子")
                let file = try fs.createGameFile(payload, stem: "\(species.fileStem)Seed", in: root)
                register(payload: file.payload, url: file.url)
            case .animal(let species):
                let payload = GameFilePayload(kind: .pet, itemType: species.rawValue, displayName: species.displayName)
                let file = try fs.createGameFile(payload, stem: species.fileStem, in: root)
                register(payload: file.payload, url: file.url)
                let name = AnimalSpecies.names.randomElement(using: &rng) ?? "小可爱"
                game.pets.append(PetState(id: file.payload.id, species: species, name: name, position: randomPetPosition(), bornAt: now))
                events.send(.petAdded(petID: file.payload.id))
            case .machine(let type):
                let folder = try fs.createManagedFolder(baseName: type.folderName, marker: FolderMarker(role: .machine, machineType: type))
                game.machines.append(MachineState(id: folder.marker.id, type: type))
            case .tool(let tool):
                let payload = GameFilePayload(kind: .tool, itemType: tool.rawValue, displayName: tool.fileStem)
                let file = try fs.createGameFile(payload, stem: tool.fileStem, in: root, preferBareName: true)
                register(payload: file.payload, url: file.url)
            case .trough:
                _ = try fs.createManagedFolder(baseName: StarterFolder.trough, marker: FolderMarker(role: .trough))
            case .crate:
                _ = try fs.createManagedFolder(baseName: "📦自定义木筐", marker: FolderMarker(role: .crate))
            case .upgrade(let upgrade):
                game.upgrades.append(upgrade)
            }
        } catch {
            report("购买失败：\(error.localizedDescription)")
            return false
        }
        game.coins -= product.price
        notify(product.emoji, "购买了\(product.displayName)（-\(product.price) 金币）")
        events.send(.purchased(name: product.displayName))
        rescan()
        dirty = true
        save() // coins and files changed together: persist now, not at the next autosave
        onWorldChanged?()
        return true
    }

    // MARK: - Shipping bin

    var shippingFiles: [ScannedFile] {
        scan.files.filter { $0.role == .shippingBin && $0.payload.kind == .item && $0.signatureValid }
    }

    var shippingValue: Int { SmartCrateMonitor.value(of: shippingFiles) }

    /// Sells everything in the shipping bin. Returns coins earned.
    @discardableResult
    func shipNow(reason: String = "立即出货") -> Int {
        let files = shippingFiles
        guard !files.isEmpty else { return 0 }
        var total = 0
        var shipped = 0
        for file in files {
            guard let type = file.payload.itemValue else { continue }
            do {
                try consume(file)
                total += type.price(quality: file.payload.qualityValue)
                shipped += 1
            } catch {
                report("出货失败：\(error.localizedDescription)")
            }
        }
        earn(total)
        grantXP(Progression.shippingXP(coins: total))
        game.stats.itemsShipped += shipped
        notify("💰", "\(reason)：卖出 \(shipped) 件，入账 \(total) 金币")
        events.send(.shipped(coins: total))
        rescan()
        dirty = true
        save() // coins and files changed together: persist now, not at the next autosave
        onWorldChanged?()
        return total
    }

    func dailyRolloverIfNeeded(now: Date) {
        let today = DayStamp.string(for: now)
        guard today != game.lastDailyRollover else { return }
        game.lastDailyRollover = today
        if !shippingFiles.isEmpty { shipNow(reason: "每日自动结算") }
        dirty = true
    }

    // MARK: - Order board

    /// Items usable for orders: delivery box first, then crates.
    var orderPool: [ScannedFile] {
        scan.files.filter { $0.role == .orderBox } + scan.files.filter { $0.role == .crate }
    }

    func canFulfil(_ order: FarmOrder) -> Bool {
        EconomyEngine.fulfilmentPlan(for: order, pool: orderPool) != nil
    }

    @discardableResult
    func completeOrder(_ orderID: UUID, now: Date = Date()) -> Bool {
        guard let index = game.orders.firstIndex(where: { $0.id == orderID }) else { return false }
        let order = game.orders[index]
        guard let picked = EconomyEngine.fulfilmentPlan(for: order, pool: orderPool) else {
            report("物品不足，无法交付\(order.requester)的订单")
            return false
        }
        for file in picked {
            do { try consume(file) } catch {
                report("交付失败：\(error.localizedDescription)")
                rescan()
                return false
            }
        }
        game.orders.remove(at: index)
        earn(order.rewardCoins)
        grantXP(order.rewardXP)
        game.stats.ordersCompleted += 1
        game.nextOrderAt = now.addingTimeInterval(EconomyEngine.orderRespawnDelay)
        notify("📋", "完成\(order.requester)的订单：+\(order.rewardCoins) 金币 +\(order.rewardXP) XP")
        events.send(.orderCompleted(coins: order.rewardCoins))
        rescan()
        dirty = true
        save() // coins and files changed together: persist now, not at the next autosave
        onWorldChanged?()
        return true
    }

    func refreshOrders(now: Date = Date()) {
        guard game.coins >= EconomyEngine.orderRefreshCost else {
            report("刷新订单需要 \(EconomyEngine.orderRefreshCost) 金币")
            return
        }
        game.coins -= EconomyEngine.orderRefreshCost
        game.orders = (0..<EconomyEngine.orderSlots).map { _ in EconomyEngine.generateOrder(level: game.level, now: now, using: &rng) }
        game.nextOrderAt = nil
        log("📋", "订单板刷新了")
        dirty = true
    }

    func maintainOrders(now: Date) {
        let before = game.orders.count
        game.orders.removeAll { $0.expiresAt <= now }
        if game.orders.count < before { log("⌛️", "有订单过期了") }
        if game.orders.isEmpty && game.nextOrderAt == nil {
            game.orders = (0..<EconomyEngine.orderSlots).map { _ in EconomyEngine.generateOrder(level: game.level, now: now, using: &rng) }
            return
        }
        guard game.orders.count < EconomyEngine.orderSlots else {
            game.nextOrderAt = nil
            return
        }
        if let next = game.nextOrderAt, now < next { return }
        game.orders.append(EconomyEngine.generateOrder(level: game.level, now: now, using: &rng))
        game.nextOrderAt = game.orders.count < EconomyEngine.orderSlots ? now.addingTimeInterval(EconomyEngine.orderRespawnDelay) : nil
        dirty = true
    }

    // MARK: - Automation

    /// Moves loose item files from the field into the matching crates.
    @discardableResult
    func tidyDesktop(silent: Bool = false) -> Int {
        let crates = scan.folders(role: .crate)
        guard !crates.isEmpty else {
            if !silent { report("没有木筐可以收纳") }
            return 0
        }
        let loose = scan.files.filter {
            $0.role == .field && $0.payload.kind == .item && $0.signatureValid && $0.payload.itemValue != .witheredClone
        }
        var moved = 0
        for file in loose {
            guard let type = file.payload.itemValue else { continue }
            let target = crates.first { $0.marker?.crateCategory == type.crateCategory }
                ?? crates.first { $0.marker?.crateCategory == nil }
                ?? crates[0]
            if (try? fs.move(file.url, into: target.url)) != nil { moved += 1 }
        }
        if moved > 0 {
            rescan()
            if !silent { notify("🧹", "整理桌面：\(moved) 件物品已归拢进木筐") }
            events.send(.tidied(count: moved))
            onWorldChanged?()
        } else if !silent {
            toast = Toast(icon: "🧹", text: "桌面很整洁，没有需要整理的物品")
        }
        return moved
    }

    func runHarvestSpriteIfNeeded(now: Date) {
        guard game.hasUpgrade(.harvestSprite), now.timeIntervalSince(lastSpriteRunAt) >= 8 else { return }
        lastSpriteRunAt = now
        let harvested = harvestAll()
        let moved = tidyDesktop(silent: true)
        if harvested + moved > 0 {
            log("🤖", "收获小精灵：收获 \(harvested) 件，归拢 \(moved) 件")
        }
    }

    // MARK: - Offline settlement

    /// Re-simulates the period the app was closed (capped at 72 h).
    func settleOffline(from start: Date, to end: Date) {
        let total = min(end.timeIntervalSince(start), 72 * 3600)
        guard total > 1 else { return }
        var report = OfflineReport()
        var elapsed = 0.0
        while elapsed < total {
            let step = min(elapsed < 3600 ? 20.0 : 60.0, total - elapsed)
            elapsed += step
            let moment = start.addingTimeInterval(elapsed)
            // Offline time is always settled at 1×: the speed setting only accelerates active play.
            report.merge(advanceWorld(dt: step, now: moment, offline: true))
        }
        rescan()
        let duration = Formatters.duration(total)
        if report.isEmpty {
            notify("🌙", "欢迎回来！离开了 \(duration)")
        } else {
            notify("🌅", "欢迎回来！离开 \(duration) 期间产出：\(report.summary)")
        }
        dirty = true
    }

    // MARK: - Reset

    /// Deletes only validated game files and our own (then empty) folders.
    func resetGame(now: Date = Date()) {
        rescan()
        for file in scan.files {
            try? fs.delete(file.url)
        }
        for folder in scan.folders where folder.marker != nil {
            fs.removeManagedFolderIfEmpty(folder.url)
        }
        saveManager.deleteSave()
        game = SaveGame.fresh(at: now)
        bootstrapLayout(now: now)
        reconcile(now: now)
        maintainOrders(now: now)
        save()
        notify("🔄", "农场已重置")
    }
}
