import Foundation

/// Player-facing actions on plants and animals.
extension GameEngine {
    // MARK: - Watering

    func water(_ plantID: UUID, now: Date = Date()) {
        guard let index = game.plantIndex(plantID) else { return }
        BotanyEngine.water(&game.plants[index], now: now)
        events.send(.watered(plantID: plantID))
        dirty = true
        onWorldChanged?()
    }

    @discardableResult
    func waterAll(inDirectory directory: String? = nil) -> Int {
        var count = 0
        for plant in game.plants where plant.moisture < 95 {
            if let directory, scan.file(id: plant.id)?.directory != directory { continue }
            water(plant.id)
            count += 1
        }
        if count > 0 { log("💧", "给 \(count) 株植物浇了水") }
        return count
    }

    // MARK: - Harvest & planting

    /// Harvests a ripe annual crop: the `.crop` file itself becomes the first fruit file.
    @discardableResult
    func harvest(_ plantID: UUID) -> Int {
        guard let index = game.plantIndex(plantID), game.plants[index].isRipeCrop,
              let file = scan.file(id: plantID) else { return 0 }
        let plant = game.plants[index]
        let qualities = BotanyEngine.harvestQualities(for: plant, using: &rng)
        let produce = plant.species.produce
        let directory = file.url.deletingLastPathComponent()
        do {
            let first = GameFilePayload(kind: .item, itemType: produce.rawValue, quality: (qualities.first ?? .normal).rawValue, displayName: produce.displayName)
            let created = try fs.transform(file.url, into: first, stem: produce.fileStem)
            register(payload: created.payload, url: created.url)
            markSpent(plantID)
            game.plants.remove(at: index)
            grantXP(produce.productionXP)
            var total = 1
            for quality in qualities.dropFirst() where createItem(produce, quality: quality, in: directory) != nil {
                total += 1
            }
            game.stats.cropsHarvested += total
            log("🧺", "收获了 \(total) 个\(produce.emoji)\(produce.displayName)")
            events.send(.harvested(plantID: plantID, item: produce, count: total))
            rescan()
            onWorldChanged?()
            return total
        } catch {
            report("收获失败：\(error.localizedDescription)")
            return 0
        }
    }

    @discardableResult
    func harvestAll() -> Int {
        let ripe = game.plants.filter(\.isRipeCrop).map(\.id)
        return ripe.reduce(0) { $0 + harvest($1) }
    }

    /// Turns a `.seed` packet into a planted `.crop` / `.tree` file in the same folder.
    @discardableResult
    func plant(seedFileID: UUID, now: Date = Date()) -> UUID? {
        guard let file = scan.file(id: seedFileID), case .seed(let species) = file.payload.subject, file.signatureValid else { return nil }
        let payload = GameFilePayload(kind: species.fileKind, itemType: species.rawValue, displayName: species.displayName)
        do {
            let created = try fs.transform(file.url, into: payload, stem: species.fileStem)
            register(payload: created.payload, url: created.url)
            markSpent(seedFileID)
            game.plants.append(PlantState(id: created.payload.id, species: species, plantedAt: now))
            log("🌱", "播种了\(species.displayName)")
            events.send(.planted(plantID: created.payload.id))
            rescan()
            onWorldChanged?()
            return created.payload.id
        } catch {
            report("播种失败：\(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func plantAllSeeds() -> Int {
        let seeds = scan.files.filter { $0.payload.kind == .seed && $0.signatureValid && $0.role == .field }.map(\.payload.id)
        return seeds.compactMap { plant(seedFileID: $0) }.count
    }

    // MARK: - Animals

    /// Feeds a specific food file to a pet (deleting the file). Returns success.
    @discardableResult
    func feedPet(_ petID: UUID, with food: ScannedFile, silent: Bool = false, now: Date = Date()) -> Bool {
        guard let index = game.petIndex(petID), let type = food.payload.itemValue, food.signatureValid,
              game.pets[index].species.diet[type] != nil else { return false }
        do {
            try consume(food)
        } catch {
            if !silent { report("喂食失败：\(error.localizedDescription)") }
            return false
        }
        HusbandryEngine.feed(&game.pets[index], food: type, quality: food.payload.qualityValue, now: now)
        if !silent { log("😋", "\(game.pets[index].name)吃掉了 \(type.emoji)\(type.displayName)") }
        events.send(.petAte(petID: petID, food: type))
        dirty = true
        return true
    }

    /// Feeds from the best available stock: trough, loose food, then crates.
    @discardableResult
    func feedPetFromStock(_ petID: UUID) -> Bool {
        guard let pet = game.pets.first(where: { $0.id == petID }) else { return false }
        let foods = scan.files.filter { file in
            file.signatureValid && [.trough, .field, .crate].contains(file.role)
                && file.payload.itemValue.map { pet.species.diet[$0] != nil } == true
        }
        let ranked = foods.sorted { lhs, rhs in
            let rank: (ScannedFile) -> Int = { file in
                let roleRank = file.role == .trough ? 0 : (file.role == .field ? 1 : 2)
                return roleRank * 2 + (file.payload.itemValue == pet.species.favoriteFood ? 0 : 1)
            }
            return rank(lhs) < rank(rhs)
        }
        guard let food = ranked.first else {
            report("没有\(pet.species.displayName)能吃的食物了，去种点\(pet.species.favoriteFood.displayName)吧")
            return false
        }
        let ok = feedPet(petID, with: food)
        if ok { rescan(); onWorldChanged?() }
        return ok
    }

    /// Called by the AI director when a pet reaches a food target.
    @discardableResult
    func petEat(_ petID: UUID, foodFileID: UUID) -> Bool {
        guard let food = scan.file(id: foodFileID) else { return false }
        let ok = feedPet(petID, with: food)
        if ok { rescan(); onWorldChanged?() }
        return ok
    }

    /// Creates the pet's product file in the farm root.
    @discardableResult
    func petProduce(_ petID: UUID, silent: Bool = false) -> ItemType? {
        guard let index = game.petIndex(petID), game.pets[index].readyToProduce else { return nil }
        let quality = HusbandryEngine.completeProduction(&game.pets[index], using: &rng)
        let product = game.pets[index].species.product
        produceRequestedAt[petID] = nil
        guard createItem(product, quality: quality, in: root) != nil else { return nil }
        game.stats.animalProducts += 1
        if !silent { log(product.emoji, "\(game.pets[index].name)产出了 \(product.displayName)\(quality.stars)") }
        events.send(.petProduced(petID: petID, item: product))
        if !silent { rescan(); onWorldChanged?() }
        return product
    }

    func pat(_ petID: UUID) {
        guard let index = game.petIndex(petID) else { return }
        HusbandryEngine.pat(&game.pets[index])
        dirty = true
    }

    // MARK: - Tools

    /// Watering can used on a plant (drag & drop or Finder proximity).
    func useWateringCan(on plantID: UUID) {
        water(plantID)
        if let plant = game.plants.first(where: { $0.id == plantID }) {
            log("💧", "用水壶给\(plant.species.displayName)浇了水")
        }
    }

    // MARK: - Double-click from Finder

    /// Handles a game file opened from Finder. Returns a human readable message.
    @discardableResult
    func handleOpen(_ url: URL) -> String {
        guard fs.sandbox.contains(url) else {
            return "这个文件不在农场目录里，桌面牧场不会碰它。"
        }
        rescan()
        guard let relative = fs.sandbox.relativePath(for: url), let file = scan.files.first(where: { $0.relativePath == relative }) else {
            return "无法识别的农场文件。"
        }
        switch file.payload.subject {
        case .seed:
            return plant(seedFileID: file.payload.id) != nil ? "🌱 已播种！" : "播种失败"
        case .plant:
            guard let plant = game.plants.first(where: { $0.id == file.payload.id }) else { return "这株植物没有生长记录" }
            if plant.isRipeCrop {
                let count = harvest(plant.id)
                return "🧺 收获了 \(count) 个\(plant.species.produce.displayName)"
            }
            water(plant.id)
            return "💧 浇水完成：\(plant.species.displayName)（\(plant.stage.displayName)，生长 \(Int(plant.displayProgress * 100))%）"
        case .pet:
            guard let pet = game.pets.first(where: { $0.id == file.payload.id }) else { return "这只动物没有记录" }
            pat(pet.id)
            return "\(pet.species.emoji) \(pet.name)：饱食 \(Int(pet.satiety))  好感 \(Int(pet.affection))  产出 \(Int(pet.productionProgress * 100))%"
        case .item(let type):
            let quality = file.payload.qualityValue
            return "\(type.emoji) \(type.displayName) \(quality.label)\(quality.stars) · 售价 \(type.price(quality: quality)) 金币"
        case .tool(.wateringCan):
            let count = waterAll(inDirectory: file.directory)
            return "💧 水壶给同目录的 \(count) 株植物浇了水"
        case .tool(.sprinkler):
            return "⚙️ 自动洒水器正在为同目录植物补水"
        case .none:
            return "无法识别的农场文件。"
        }
    }
}
