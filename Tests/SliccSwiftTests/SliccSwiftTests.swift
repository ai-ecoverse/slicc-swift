import Testing

@testable import SliccSwift

@Test func packageName() {
  #expect(SliccSwift.name == "slicc-swift")
}
