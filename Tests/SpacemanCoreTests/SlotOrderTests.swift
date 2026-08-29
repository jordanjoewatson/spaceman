import Testing
import CoreGraphics
@testable import SpacemanCore

@Suite("Slot order")
struct SlotOrderTests {

    // MARK: - Reconciling

    @Test("unknown windows are appended in the order reported")
    func appendsNewWindows() {
        // A newly opened window lands at the end, predictably, rather than
        // somewhere in the middle of the layout.
        // Bound outside #expect: the macro captures its argument immutably, so
        // a mutating call cannot be made inside it.
        var order = SlotOrder()
        let first = order.reconcile(present: [3, 1, 2])
        #expect(first == [3, 1, 2])
        let second = order.reconcile(present: [3, 1, 2, 9])
        #expect(second == [3, 1, 2, 9])
    }

    @Test("existing windows keep their slots when a new one arrives")
    func existingSlotsSurvive() {
        // The whole reason slot order exists: opening a window must not
        // reshuffle the ones already placed.
        var order = SlotOrder([5, 6, 7])
        let result = order.reconcile(present: [7, 5, 6, 8])
        #expect(result == [5, 6, 7, 8], "server order does not disturb known slots")
    }

    @Test("closed windows are dropped and the rest close up")
    func dropsClosedWindows() {
        var order = SlotOrder([1, 2, 3, 4])
        let result = order.reconcile(present: [1, 3])
        #expect(result == [1, 3])
    }

    @Test("reconciling is idempotent")
    func reconcileIsIdempotent() {
        var order = SlotOrder()
        let first = order.reconcile(present: [4, 5, 6])
        let again = order.reconcile(present: [4, 5, 6])
        #expect(again == first)
    }

    @Test("an empty window set empties the order")
    func emptiesWhenNothingIsPresent() {
        var order = SlotOrder([1, 2])
        let result = order.reconcile(present: [])
        #expect(result.isEmpty)
        #expect(order.isEmpty)
    }

    // MARK: - Swapping

    @Test("swapping exchanges two slots and leaves the rest alone")
    func swapsTwoSlots() {
        var order = SlotOrder([1, 2, 3, 4])
        let swapped = order.swap(2, 4)
        #expect(swapped)
        #expect(order.ids == [1, 4, 3, 2])
    }

    @Test("swapping is symmetric")
    func swapIsSymmetric() {
        var forward = SlotOrder([1, 2, 3])
        var backward = SlotOrder([1, 2, 3])
        _ = forward.swap(1, 3)
        _ = backward.swap(3, 1)
        #expect(forward == backward)
    }

    @Test("swapping twice returns to where it started")
    func swapIsItsOwnInverse() {
        var order = SlotOrder([1, 2, 3, 4])
        _ = order.swap(1, 4)
        _ = order.swap(1, 4)
        #expect(order.ids == [1, 2, 3, 4])
    }

    @Test("a meaningless swap reports false and changes nothing")
    func rejectsMeaninglessSwaps() {
        // So the caller can skip the re-tile instead of issuing a pass that
        // moves nothing.
        var order = SlotOrder([1, 2, 3])
        let same = order.swap(2, 2)
        let unknown = order.swap(1, 99)
        let neither = order.swap(99, 98)
        #expect(!same, "the same window twice")
        #expect(!unknown, "a window holding no slot here")
        #expect(!neither, "neither window known")
        #expect(order.ids == [1, 2, 3])
    }

    @Test("a swap survives reconciling")
    func swapPersistsThroughReconcile() {
        // This is what makes a swap stick: the order *is* the model, so the next
        // tiling pass lays out against it rather than re-deriving it.
        var order = SlotOrder([1, 2, 3])
        _ = order.swap(1, 3)
        let result = order.reconcile(present: [1, 2, 3])
        #expect(result == [3, 2, 1])
    }

    @Test("a swap survives an unrelated window opening")
    func swapSurvivesNewWindow() {
        var order = SlotOrder([1, 2, 3])
        _ = order.swap(1, 3)
        let result = order.reconcile(present: [1, 2, 3, 4])
        #expect(result == [3, 2, 1, 4])
    }

    @Test("closing a swapped window leaves the other where it was put")
    func swapSurvivesClose() {
        var order = SlotOrder([1, 2, 3])
        _ = order.swap(1, 3)      // [3, 2, 1]
        let result = order.reconcile(present: [2, 3])
        #expect(result == [3, 2])
    }

    @Test("slot lookup reports the index a window holds")
    func reportsSlot() {
        var order = SlotOrder([7, 8, 9])
        #expect(order.slot(of: 8) == 1)
        _ = order.swap(7, 9)
        #expect(order.slot(of: 7) == 2)
        #expect(order.slot(of: 42) == nil)
    }
}
