import Foundation

/// File-backed primitives: every mutation keeps ledger and disk in step.
extension GameEngine {
    // MARK: - Ledger

    func register(payload: GameFilePayload, url: URL, inode: UInt64? = nil) {
        let entry = LedgerEntry(
            id: payload.id,
            kind: payload.kind,
            itemType: payload.itemType,
            quality: payload.quality,
            inode: inode ?? fs.inode(of: url),
            relativePath: fs.sandbox.relativePath(for: url) ?? url.lastPathComponent,
            registeredAt: Date(),
            missingSince: nil
        )
        if let index = game.ledgerIndex(payload.id) {
            game.ledger[index] = entry
        } else {
            game.ledger.append(entry)
        }
    }

    func markSpent(_ id: UUID) {
        game.ledger.removeAll { $0.id == id }
        game.spentIDs.append(id)
        // Fast-path memory only: resurrection protection does not depend on this list
        // (see `GameEngine.registeredWindow`), so trimming very old ids is safe.
        if game.spentIDs.count > 20_000 { game.spentIDs.removeFirst(game.spentIDs.count - 20_000) }
    }

    // MARK: - Items

    @discardableResult
    func createItem(_ type: ItemType, quality: Quality, in directory: URL, grantProductionXP: Bool = true, id: UUID = UUID()) -> URL? {
        let payload = GameFilePayload(id: id, kind: .item, itemType: type.rawValue, quality: quality.rawValue, displayName: type.displayName)
        do {
            let created = try fs.createGameFile(payload, stem: type.fileStem, in: directory)
            register(payload: created.payload, url: created.url)
            if grantProductionXP { grantXP(type.productionXP) }
            return created.url
        } catch {
            report("无法生成\(type.displayName)：\(error.localizedDescription)")
            return nil
        }
    }

    /// Deletes a validated game file and marks its id as spent forever.
    func consume(_ file: ScannedFile) throws {
        try fs.delete(file.url)
        markSpent(file.payload.id)
    }

    /// Rewrites a duplicate / forged file into a worthless withered clone.
    func witherClone(_ file: ScannedFile) {
        let originalName = file.payload.subject?.displayName ?? file.name
        let payload = GameFilePayload(kind: .item, itemType: ItemType.witheredClone.rawValue, quality: 1, displayName: "🥀枯萎的克隆果")
        do {
            let created = try fs.transform(file.url, into: payload, stem: ItemType.witheredClone.fileStem)
            register(payload: created.payload, url: created.url)
            game.stats.clonesCaught += 1
            notify("🥀", "检测到复制的「\(originalName)」，它枯萎成了克隆果（价值 0）")
            events.send(.cloneDetected(name: originalName))
        } catch {
            report("处理克隆文件失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Progression

    func grantXP(_ amount: Int) {
        guard amount > 0 else { return }
        let before = game.level
        game.xp += amount
        let after = game.level
        if after > before {
            notify("🎉", "升级啦！农场等级 Lv.\(after)，商店解锁了新商品")
            events.send(.levelUp(level: after))
        }
    }

    func earn(_ coins: Int) {
        guard coins > 0 else { return }
        game.coins += coins
        game.stats.coinsEarned += coins
    }

    // MARK: - Trees

    /// A grown tree drops 2~4 real fruit files next to itself.
    @discardableResult
    func dropFruit(plantIndex: Int, file: ScannedFile) -> Int {
        let plant = game.plants[plantIndex]
        let qualities = BotanyEngine.harvestQualities(for: plant, using: &rng)
        let directory = file.url.deletingLastPathComponent()
        var created = 0
        for quality in qualities where createItem(plant.species.produce, quality: quality, in: directory) != nil {
            created += 1
        }
        BotanyEngine.resetAfterHarvest(&game.plants[plantIndex])
        guard created > 0 else { return 0 }
        game.stats.fruitsDropped += created
        log(plant.species.produce.emoji, "\(plant.species.displayName)掉落了 \(created) 个\(plant.species.produce.displayName)")
        events.send(.fruitDropped(plantID: plant.id, item: plant.species.produce, count: created))
        return created
    }

    // MARK: - Machines

    /// Starts jobs in idle machines whose folder holds a complete recipe.
    @discardableResult
    func processMachines(now: Date = Date()) -> Bool {
        var changed = false
        for folder in scan.folders(role: .machine) {
            guard let marker = folder.marker, let type = marker.machineType,
                  let index = game.machineIndex(marker.id), game.machines[index].job == nil else { continue }
            let loose = scan.files(inFolder: marker.id, role: .machine)
            guard let plan = ProcessingMachineEngine.plan(for: type, available: loose) else { continue }
            do {
                let staging = try fs.processingFolder(in: folder.url)
                var moved: [UUID] = []
                for input in plan.inputs {
                    try fs.move(input.url, into: staging)
                    moved.append(input.payload.id)
                }
                game.machines[index].job = MachineJob(
                    output: plan.recipe.output,
                    inputIDs: moved,
                    quality: plan.quality.rawValue,
                    duration: plan.recipe.duration,
                    elapsed: 0,
                    startedAt: now,
                    outputID: UUID()
                )
                changed = true
                log("⚙️", "\(type.displayName)开始加工 \(plan.recipe.output.emoji)\(plan.recipe.output.displayName)")
                events.send(.machineStarted(machineID: marker.id))
            } catch {
                report("\(type.displayName)无法开工：\(error.localizedDescription)")
            }
        }
        // Persist immediately: inputs now sit in .processing and must never be orphaned.
        if changed { save() }
        return changed
    }

    /// Repairs machine state against what is really on disk (crash, manual tampering):
    /// - no job, but files in `.processing/` → return them to the machine folder;
    /// - job whose locked inputs were removed (and no product yet) → cancel, return the rest;
    /// - stray files in `.processing/` that the job does not own → return them;
    /// - finished job whose completion did not land → complete it now.
    @discardableResult
    func recoverMachines(now: Date = Date()) -> Bool {
        var mutated = false
        for folder in scan.folders(role: .machine) {
            guard let id = folder.marker?.id, let index = game.machineIndex(id) else { continue }
            let staged = scan.files(inFolder: id, role: .processing)
            var toReturn: [ScannedFile] = []
            if let job = game.machines[index].job {
                let present = Set(staged.map(\.payload.id))
                let productDone = job.outputID.map { scan.file(id: $0) != nil } ?? false
                if !productDone && job.inputIDs.contains(where: { !present.contains($0) }) {
                    game.machines[index].job = nil
                    toReturn = staged
                    log("⚠️", "\(game.machines[index].type.displayName)的原料被移走，加工已取消，剩余原料已退回")
                } else {
                    toReturn = staged.filter { !job.inputIDs.contains($0.payload.id) }
                }
            } else if !staged.isEmpty {
                toReturn = staged
                log("🔧", "\(game.machines[index].type.displayName)：恢复了 \(staged.count) 件未完成加工的原料")
            }
            for file in toReturn where (try? fs.move(file.url, into: folder.url)) != nil {
                mutated = true
            }
            if toReturn.isEmpty == false || game.machines[index].job == nil {
                fs.removeEmptyProcessingFolder(in: folder.url)
            }
        }
        if mutated { rescan() }
        var completed = false
        for index in game.machines.indices where game.machines[index].job?.isFinished == true {
            if finishJob(machineIndex: index, silent: false) != nil { completed = true }
        }
        if completed { rescan() }
        return mutated || completed
    }

    /// Completes a finished job. Order is crash-safe and idempotent:
    /// 1. write the product with the job's pre-assigned id (skipped if it already exists),
    /// 2. consume the locked inputs (marked spent even if the delete fails, so a leftover
    ///    can only ever wither — never feed a second job),
    /// 3. clear the job and persist.
    func finishJob(machineIndex index: Int, silent: Bool) -> ItemType? {
        guard let job = game.machines[index].job else { return nil }
        let machineID = game.machines[index].id
        guard let folder = scan.folder(id: machineID) else {
            game.machines[index].job = nil
            return nil
        }
        let staged = scan.files(inFolder: machineID, role: .processing)
        let inputs = staged.filter { job.inputIDs.contains($0.payload.id) }
        let outputID = job.outputID ?? UUID()
        let productExists = scan.file(id: outputID) != nil
        guard productExists || inputs.count == job.inputIDs.count else {
            game.machines[index].job = nil
            log("⚠️", "\(game.machines[index].type.displayName)的原料丢失，加工中止")
            return nil
        }
        if !productExists {
            // On failure the job stays finished and completion is retried next tick.
            guard createItem(job.output, quality: Quality.clamped(job.quality), in: folder.url, id: outputID) != nil else { return nil }
        }
        for input in inputs {
            try? fs.delete(input.url)
            markSpent(input.payload.id)
        }
        game.machines[index].job = nil
        game.machines[index].completedJobs += 1
        game.stats.goodsProcessed += 1
        if !silent {
            notify("✨", "\(game.machines[index].type.displayName)完工：\(job.output.emoji)\(job.output.displayName) 待收取")
        }
        events.send(.machineFinished(machineID: machineID, item: job.output))
        fs.removeEmptyProcessingFolder(in: folder.url)
        if !silent { save() }
        return job.output
    }

    // MARK: - Food

    func troughFood(for species: AnimalSpecies) -> ScannedFile? {
        let foods = scan.files.filter { file in
            file.role == .trough && file.signatureValid
                && file.payload.itemValue.map { species.diet[$0] != nil } == true
        }
        return foods.first { $0.payload.itemValue == species.favoriteFood } ?? foods.first
    }

    // MARK: - Layout bootstrap

    func bootstrapLayout(now: Date) {
        let starters: [(String, FolderMarker)] = [
            (StarterFolder.produceCrate, FolderMarker(role: .crate, crateCategory: .produce)),
            (StarterFolder.ranchCrate, FolderMarker(role: .crate, crateCategory: .ranch)),
            (StarterFolder.shippingBin, FolderMarker(role: .shippingBin)),
            (StarterFolder.orderBox, FolderMarker(role: .orderBox))
        ]
        let existing = scanner.scan(now: now)
        for (name, marker) in starters {
            let alreadyHasRole = existing.folders.contains { folder in
                folder.role == marker.role && (marker.role != .crate || folder.marker?.crateCategory == marker.crateCategory)
            }
            if alreadyHasRole { continue }
            do {
                try fs.ensureManagedFolder(named: name, marker: marker)
            } catch {
                report("无法创建「\(name)」：\(error.localizedDescription)")
            }
        }
        guard !game.bootstrapped else { return }
        createStarterKit(now: now)
        game.bootstrapped = true
        dirty = true
    }

    private func createStarterKit(now: Date) {
        do {
            let trough = try fs.ensureManagedFolder(named: StarterFolder.trough, marker: FolderMarker(role: .trough))
            let jam = try fs.ensureManagedFolder(named: MachineType.jamMaker.folderName, marker: FolderMarker(role: .machine, machineType: .jamMaker))
            game.machines.append(MachineState(id: jam.marker.id, type: .jamMaker))

            let can = GameFilePayload(kind: .tool, itemType: ToolType.wateringCan.rawValue, displayName: "💧水壶")
            let canFile = try fs.createGameFile(can, stem: ToolType.wateringCan.fileStem, in: root, preferBareName: true)
            register(payload: canFile.payload, url: canFile.url)

            for species in [PlantSpecies.wheat, .wheat, .hay] {
                let seed = GameFilePayload(kind: .seed, itemType: species.rawValue, displayName: "\(species.displayName)种子")
                let file = try fs.createGameFile(seed, stem: "\(species.fileStem)Seed", in: root)
                register(payload: file.payload, url: file.url)
            }

            let tree = GameFilePayload(kind: .tree, itemType: PlantSpecies.appleTree.rawValue, displayName: "苹果树")
            let treeFile = try fs.createGameFile(tree, stem: PlantSpecies.appleTree.fileStem, in: root)
            register(payload: treeFile.payload, url: treeFile.url)
            var treeState = PlantState(id: treeFile.payload.id, species: .appleTree, plantedAt: now, moisture: 85)
            treeState.growth = 0.25
            game.plants.append(treeState)

            let chick = GameFilePayload(kind: .pet, itemType: AnimalSpecies.chicken.rawValue, displayName: "小鸡")
            let chickFile = try fs.createGameFile(chick, stem: AnimalSpecies.chicken.fileStem, in: root)
            register(payload: chickFile.payload, url: chickFile.url)
            game.pets.append(PetState(id: chickFile.payload.id, species: .chicken, name: "豆豆", position: UnitPoint2D(x: 0.55, y: 0.18), bornAt: now))

            for _ in 0..<2 {
                createItem(.wheat, quality: .normal, in: trough.url, grantProductionXP: false)
            }
            log("🌾", "欢迎来到桌面牧场！农场目录：\(root.path)")
        } catch {
            report("初始化新手农场失败：\(error.localizedDescription)")
        }
    }
}
