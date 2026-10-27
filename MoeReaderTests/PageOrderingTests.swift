import XCTest
@testable import MoeReader

final class PageOrderingTests: XCTestCase {
    func testNaturalOrderAndLeadingZeros() {
        let names = ["10.jpg", "2.jpg", "001.jpg", "1.jpg", "a.jpg"]
        XCTAssertEqual(
            PageOrdering.sortedImageNames(names),
            ["1.jpg", "001.jpg", "2.jpg", "10.jpg", "a.jpg"]
        )
    }

    func testSortingIsCaseInsensitiveWithRawTieBreak() {
        XCTAssertEqual(
            PageOrdering.sortedImageNames(["B.PNG", "a.png", "b.png", "A.png"]),
            ["A.png", "a.png", "B.PNG", "b.png"]
        )
    }

    func testRejectsJunkAndDirectories() {
        let names = [
            ".DS_Store",
            "._page-1.jpg",
            "__MACOSX/page-2.jpg",
            "sub/__MACOSX/page-3.jpg",
            ".hidden/page-4.jpg",
            "folder/",
            "notes.txt",
            "page-5.jpg",
        ]
        XCTAssertEqual(PageOrdering.sortedImageNames(names), ["page-5.jpg"])
    }

    func testAcceptsSupportedExtensionsCaseInsensitively() {
        let names = ["a.JPG", "b.jpeg", "c.PNG", "d.webp", "e.gif", "f.heic", "g.heif", "h.avif", "i.bmp", "j.tif", "k.tiff"]
        XCTAssertEqual(PageOrdering.sortedImageNames(names).count, names.count)
    }
}
