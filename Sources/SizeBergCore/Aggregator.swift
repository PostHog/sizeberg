import Foundation

/// Private size of a clone whose siblings the scan did not see, from an earlier lookup.
/// Valid while the file keeps its inode and size and stays the only member of its family.
struct KnownPrivateSize {
    var cloneID: UInt64
    var inode: UInt64
    var privateBytes: Int64
    var blocks: UInt32
    var device: Int32

    var key: FileKey {
        FileKey(device: device, id: cloneID)
    }
}

/// Turns per-group scans into byte totals: builds clone and hard-link families across all groups,
/// then splits every shared block into "frees alone" or a shared set.
struct Aggregator {
    struct Result {
        var apparentBytes: [Int64]
        var privateBytes: [Int64]
        var freeableAloneBytes: [Int64]
        var fileCounts: [Int]
        var sets: [GroupSet: SetTotal]
        var privateSizes: [KnownPrivateSize]
        /// Last full clones that still share blocks with files that are not full clones: copies changed
        /// after cloning. Those copies form other families and may sit inside the scan, where their
        /// families then look freeable although these blocks stay. Up to this much can be overstated.
        var changedCloneBytes: Int64
        var changedCloneFiles: Int
    }

    struct SetTotal {
        var bytes: Int64 = 0
        var families = 0

        mutating func add(_ bytes: Int64, families: Int = 1) {
            self.bytes += bytes
            self.families += families
        }
    }

    private struct Partial {
        var apparentBytes: [Int64]
        var privateBytes: [Int64]
        var bucketShared: [Int64]
        var sets: [GroupSet: SetTotal] = [:]
        var privateSizes: [KnownPrivateSize] = []
        var lookups = 0
        var changedCloneBytes: Int64 = 0
        var changedCloneFiles = 0

        init(bucketCount: Int) {
            apparentBytes = Array(repeating: 0, count: bucketCount)
            privateBytes = Array(repeating: 0, count: bucketCount)
            bucketShared = Array(repeating: 0, count: bucketCount)
        }

        mutating func addToSet(_ set: GroupSet, bytes: Int64) {
            sets[set, default: SetTotal()].add(bytes)
        }
    }

    private static let kindsPerGroup = BucketKind.allCases.count

    /// Indexed by group. Nil for groups that are not walked.
    let scans: [GroupScan?]
    var knownPrivateSizes: [FileKey: KnownPrivateSize] = [:]
    var isDebugging = false

    func run() -> Result {
        let started = Date()
        let bucketCount = scans.count * Self.kindsPerGroup
        let families = buildFamilies()
        let built = Date()
        let partials = Locked([Partial]())
        DispatchQueue.concurrentPerform(iterations: families.shards.count) { index in
            let partial = summarize(families.shards[index], bucketCount: bucketCount)
            partials.withLock { $0.append(partial) }
        }

        var result = Result(
            apparentBytes: Array(repeating: 0, count: bucketCount),
            privateBytes: Array(repeating: 0, count: bucketCount),
            freeableAloneBytes: Array(repeating: 0, count: bucketCount),
            fileCounts: Array(repeating: 0, count: bucketCount),
            sets: [:],
            privateSizes: [],
            changedCloneBytes: 0,
            changedCloneFiles: 0
        )
        var lookups = 0
        if isDebugging {
            var cloneFamilies = 0
            var singletons = 0
            var hardLinks = 0
            for shard in families.shards {
                cloneFamilies += shard.clones.count
                singletons += shard.clones.values.filter { $0.members == 1 }.count
                hardLinks += shard.hardLinks.count
            }
            let entries = scans.reduce(0) { $0 + ($1?.entries.count ?? 0) }
            let message = String(
                format: "families %.1f s, summaries %.1f s; %d entries, %d clone families, %d singletons, %d hard links\n",
                built.timeIntervalSince(started), Date().timeIntervalSince(built), entries, cloneFamilies, singletons, hardLinks
            )
            FileHandle.standardError.write(Data(message.utf8))
        }
        var bucketShared = [Int64](repeating: 0, count: bucketCount)
        for partial in partials.withLock({ $0 }) {
            for bucket in 0..<bucketCount {
                result.apparentBytes[bucket] += partial.apparentBytes[bucket]
                result.privateBytes[bucket] += partial.privateBytes[bucket]
                bucketShared[bucket] += partial.bucketShared[bucket]
            }
            for (set, value) in partial.sets {
                result.sets[set, default: SetTotal()].add(value.bytes, families: value.families)
            }
            result.privateSizes += partial.privateSizes
            result.changedCloneBytes += partial.changedCloneBytes
            result.changedCloneFiles += partial.changedCloneFiles
            lookups += partial.lookups
        }
        for (group, scan) in scans.enumerated() {
            guard let scan else { continue }
            for kind in 0..<Self.kindsPerGroup {
                let bucket = group * Self.kindsPerGroup + kind
                result.apparentBytes[bucket] += scan.apparentBytes[kind]
                result.privateBytes[bucket] += scan.unsharedBytes[kind]
                result.fileCounts[bucket] = scan.fileCounts[kind]
            }
        }
        for bucket in 0..<bucketCount {
            result.freeableAloneBytes[bucket] = result.privateBytes[bucket] + bucketShared[bucket]
        }
        if isDebugging {
            FileHandle.standardError.write(Data("private size lookups: \(lookups) of \(result.privateSizes.count)\n".utf8))
        }
        return result
    }

    /// Each thread reads every entry but keeps only keys of its own shard: a few cheap passes
    /// over memory beat millions of locked dictionary updates.
    private func buildFamilies() -> FamilyTable {
        let families = FamilyTable()
        let walked = scans.indices.filter { scans[$0] != nil }
        let entryCount = walked.reduce(0) { $0 + (scans[$1]?.entries.count ?? 0) }
        // Clones in dependency trees come in families of several, so this rarely has to grow.
        let expectedPerShard = entryCount / FamilyTable.shardCount / 4
        DispatchQueue.concurrentPerform(iterations: FamilyTable.shardCount) { shardIndex in
            let shard = families.shards[shardIndex]
            shard.clones.reserveCapacity(expectedPerShard)
            for group in walked {
                guard let scan = scans[group] else { continue }
                let base = group * Self.kindsPerGroup
                for entry in scan.entries {
                    let bucket = base + Int(entry.kind)
                    if entry.isHardLink {
                        guard FamilyTable.shardIndex(for: entry.inode) == shardIndex else { continue }
                        let key = FileKey(device: scan.device, id: entry.inode)
                        var family = shard.hardLinks[key] ?? Family()
                        family.add(sharedBytes: entry.allocatedBytes, group: group, bucket: bucket, device: scan.device, inode: entry.inode)
                        family.expectedMembers = UInt32(entry.copies)
                        family.sharesBlocksOutside = family.sharesBlocksOutside || entry.isClonedElsewhere
                        shard.hardLinks[key] = family
                    } else {
                        guard FamilyTable.shardIndex(for: entry.cloneID) == shardIndex else { continue }
                        let key = FileKey(device: scan.device, id: entry.cloneID)
                        var family = shard.clones[key] ?? Family()
                        family.add(sharedBytes: entry.allocatedBytes, group: group, bucket: bucket, device: scan.device, inode: entry.inode)
                        family.expectedMembers = max(family.expectedMembers, UInt32(entry.copies))
                        shard.clones[key] = family
                    }
                }
            }
        }
        return families
    }

    private func summarize(_ shard: FamilyTable.Shard, bucketCount: Int) -> Partial {
        var partial = Partial(bucketCount: bucketCount)
        let probe = PrivateSizeProbe()

        for family in shard.hardLinks.values {
            // du counts a hard-linked inode once, where it first sees it.
            partial.apparentBytes[Int(family.firstBucket)] += family.sharedBytes
            var set = family.groups
            if family.members < family.expectedMembers || family.sharesBlocksOutside {
                set.insert(GroupSet.outsideIndex)
            } else if family.bucket >= 0 {
                partial.bucketShared[Int(family.bucket)] += family.sharedBytes
            }
            partial.addToSet(set, bytes: family.sharedBytes)
        }

        for (key, family) in shard.clones {
            if family.expectedMembers > family.members {
                // Full clones outside the scan share every block, so nothing here frees them.
                var set = family.groups
                set.insert(GroupSet.outsideIndex)
                partial.addToSet(set, bytes: family.sharedBytes)
                continue
            }
            guard family.members == 1 else {
                // Every full clone found: they share every block, so all of it is shared.
                if family.bucket >= 0 {
                    partial.bucketShared[Int(family.bucket)] += family.sharedBytes
                }
                partial.addToSet(family.groups, bytes: family.sharedBytes)
                continue
            }
            // The only full clone left. Its siblings are gone, but a sibling that was changed
            // after cloning becomes a new clone family and can still share some blocks. Only APFS knows.
            let ownBytes = privateBytes(of: key, family, probe: probe, into: &partial)
            partial.privateBytes[Int(family.firstBucket)] += ownBytes
            let heldElsewhere = family.sharedBytes - ownBytes
            guard heldElsewhere > 0 else { continue }
            if family.expectedMembers == 1 {
                partial.changedCloneBytes += heldElsewhere
                partial.changedCloneFiles += 1
            }
            var set = GroupSet(Int(family.firstGroup))
            set.insert(GroupSet.outsideIndex)
            partial.addToSet(set, bytes: heldElsewhere)
        }
        return partial
    }

    private func privateBytes(of key: FileKey, _ family: Family, probe: PrivateSizeProbe, into partial: inout Partial) -> Int64 {
        let blocks = UInt32(clamping: family.sharedBytes / SharedEntry.blockSize)
        if let known = knownPrivateSizes[key], known.inode == family.firstInode, known.blocks == blocks {
            partial.privateSizes.append(known)
            return known.privateBytes
        }
        partial.lookups += 1
        // Unknown counts as held elsewhere: never report bytes as freeable without proof.
        let ownBytes = probe.privateBytes(device: family.firstDevice, inode: family.firstInode)
            .map { min(max($0, 0), family.sharedBytes) } ?? 0
        partial.privateSizes.append(KnownPrivateSize(
            cloneID: key.id, inode: family.firstInode, privateBytes: ownBytes, blocks: blocks, device: key.device
        ))
        return ownBytes
    }
}
