import XCTest
import UIKit
@testable import LovelyMusic

final class SwipeBackGestureTests: XCTestCase {
    func testSwipeBackGestureRecognizerDelegateAssignedOnViewDidLoad() {
        let navController = UINavigationController(rootViewController: UIViewController())
        _ = navController.view // triggers viewDidLoad

        XCTAssertNotNil(navController.interactivePopGestureRecognizer?.delegate)
    }

    func testSwipeBackGestureShouldBeginOnlyWhenMoreThanOneViewController() {
        let navController = UINavigationController(rootViewController: UIViewController())
        _ = navController.view

        guard let gesture = navController.interactivePopGestureRecognizer else {
            XCTFail("interactivePopGestureRecognizer is nil")
            return
        }

        // At root: viewControllers.count == 1 -> should NOT begin
        XCTAssertFalse(navController.gestureRecognizerShouldBegin(gesture))

        // Pushed child: viewControllers.count == 2 -> should begin
        navController.viewControllers.append(UIViewController())
        XCTAssertTrue(navController.gestureRecognizerShouldBegin(gesture))
    }
}
