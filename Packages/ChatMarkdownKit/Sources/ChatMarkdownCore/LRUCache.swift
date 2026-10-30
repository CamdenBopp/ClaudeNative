import Foundation

/// Cost-bounded LRU cache shared by the layout and code subsystems.
///
/// NOT thread-safe by design — every instance is confined to one owner
/// (an actor or the main thread). Keeping synchronization out of the cache
/// keeps the owners' isolation rules honest.
package final class LRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        var next: Node?        // toward least-recently-used
        weak var prev: Node?   // toward most-recently-used; weak breaks cycles

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private var nodes: [Key: Node] = [:]
    private var head: Node?  // most recently used
    private var tail: Node?  // least recently used

    package let costLimit: Int
    package private(set) var totalCost = 0

    package init(costLimit: Int) {
        self.costLimit = max(1, costLimit)
    }

    package var count: Int { nodes.count }

    package func value(for key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        moveToFront(node)
        return node.value
    }

    package func insert(_ value: Value, for key: Key, cost: Int) {
        let cost = max(1, cost)
        if let existing = nodes[key] {
            totalCost += cost - existing.cost
            existing.value = value
            existing.cost = cost
            moveToFront(existing)
        } else {
            let node = Node(key: key, value: value, cost: cost)
            nodes[key] = node
            totalCost += cost
            pushFront(node)
        }
        evictIfNeeded()
    }

    package func remove(_ key: Key) {
        guard let node = nodes.removeValue(forKey: key) else { return }
        totalCost -= node.cost
        unlink(node)
    }

    package func removeAll() {
        nodes.removeAll()
        head = nil
        tail = nil
        totalCost = 0
    }

    package func removeAll(where predicate: (Key) -> Bool) {
        for key in nodes.keys where predicate(key) {
            remove(key)
        }
    }

    // MARK: - Linked list

    private func pushFront(_ node: Node) {
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func unlink(_ node: Node) {
        if node === head { head = node.next }
        if node === tail { tail = node.prev }
        node.prev?.next = node.next
        node.next?.prev = node.prev
        node.prev = nil
        node.next = nil
    }

    private func moveToFront(_ node: Node) {
        guard node !== head else { return }
        unlink(node)
        pushFront(node)
    }

    private func evictIfNeeded() {
        while totalCost > costLimit, let victim = tail, nodes.count > 1 {
            nodes.removeValue(forKey: victim.key)
            totalCost -= victim.cost
            unlink(victim)
        }
    }
}
