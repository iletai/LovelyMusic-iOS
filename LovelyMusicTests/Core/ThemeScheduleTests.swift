import XCTest
@testable import LovelyMusic

final class ThemeScheduleTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        return calendar.date(from: comps)!
    }

    // MARK: - 1. Recurring MM-dd Date Matching

    func testRecurringDateRangeWithinSameYear() {
        let schedule = ThemeScheduleItem(
            id: "xmas",
            title: "Christmas",
            priority: 50,
            startDate: "12-20",
            endDate: "12-26",
            theme: SeasonalThemeConfig(isEnabled: true, themeName: "christmas")
        )

        // Matching Dec 24 2025
        let matchDate2025 = makeDate(year: 2025, month: 12, day: 24, hour: 10, minute: 0)
        XCTAssertTrue(schedule.matches(date: matchDate2025, calendar: calendar))

        // Matching Dec 24 2026 (recurring across different years)
        let matchDate2026 = makeDate(year: 2026, month: 12, day: 24, hour: 10, minute: 0)
        XCTAssertTrue(schedule.matches(date: matchDate2026, calendar: calendar))

        // Outside range: Dec 15 2026
        let beforeDate = makeDate(year: 2026, month: 12, day: 15, hour: 10, minute: 0)
        XCTAssertFalse(schedule.matches(date: beforeDate, calendar: calendar))

        // Outside range: Dec 28 2026
        let afterDate = makeDate(year: 2026, month: 12, day: 28, hour: 10, minute: 0)
        XCTAssertFalse(schedule.matches(date: afterDate, calendar: calendar))
    }

    func testRecurringDateRangeCrossingYearBoundary() {
        let schedule = ThemeScheduleItem(
            id: "new_year_crossover",
            title: "New Year Window",
            priority: 50,
            startDate: "12-25",
            endDate: "01-05",
            theme: SeasonalThemeConfig(isEnabled: true, themeName: "new_year")
        )

        // Dec 30
        let decDate = makeDate(year: 2025, month: 12, day: 30, hour: 12, minute: 0)
        XCTAssertTrue(schedule.matches(date: decDate, calendar: calendar))

        // Jan 2
        let janDate = makeDate(year: 2026, month: 1, day: 2, hour: 12, minute: 0)
        XCTAssertTrue(schedule.matches(date: janDate, calendar: calendar))

        // Jan 10 (outside)
        let janOutside = makeDate(year: 2026, month: 1, day: 10, hour: 12, minute: 0)
        XCTAssertFalse(schedule.matches(date: janOutside, calendar: calendar))
    }

    // MARK: - 2. Specific yyyy-MM-dd Date Matching

    func testSpecificYearDateRange() {
        let schedule = ThemeScheduleItem(
            id: "tet_2026",
            title: "Tết 2026",
            priority: 100,
            startDate: "2026-01-26",
            endDate: "2026-02-06",
            theme: SeasonalThemeConfig(isEnabled: true, themeName: "tet")
        )

        // In 2026 range: Jan 28 2026
        let inRange = makeDate(year: 2026, month: 1, day: 28, hour: 15, minute: 0)
        XCTAssertTrue(schedule.matches(date: inRange, calendar: calendar))

        // Same day but different year: Jan 28 2027 (should NOT match specific year schedule)
        let wrongYear = makeDate(year: 2027, month: 1, day: 28, hour: 15, minute: 0)
        XCTAssertFalse(schedule.matches(date: wrongYear, calendar: calendar))
    }

    // MARK: - 3. Time of Day Range Matching

    func testDaytimeRangeMatching() {
        let morning = ThemeScheduleItem(
            id: "morning",
            title: "Morning Session",
            priority: 10,
            timeRange: "05:00-11:59",
            theme: SeasonalThemeConfig(isEnabled: true, themeName: "summer")
        )

        let at8am = makeDate(year: 2026, month: 5, day: 10, hour: 8, minute: 30)
        XCTAssertTrue(morning.matches(date: at8am, calendar: calendar))

        let at2pm = makeDate(year: 2026, month: 5, day: 10, hour: 14, minute: 0)
        XCTAssertFalse(morning.matches(date: at2pm, calendar: calendar))
    }

    func testOvernightTimeRangeMatching() {
        let night = ThemeScheduleItem(
            id: "night",
            title: "Night Session",
            priority: 10,
            timeRange: "23:00-04:59",
            theme: SeasonalThemeConfig(isEnabled: true, themeName: "halloween")
        )

        let at2330 = makeDate(year: 2026, month: 5, day: 10, hour: 23, minute: 30)
        XCTAssertTrue(night.matches(date: at2330, calendar: calendar))

        let at0215 = makeDate(year: 2026, month: 5, day: 11, hour: 2, minute: 15)
        XCTAssertTrue(night.matches(date: at0215, calendar: calendar))

        let at1000 = makeDate(year: 2026, month: 5, day: 11, hour: 10, minute: 0)
        XCTAssertFalse(night.matches(date: at1000, calendar: calendar))
    }

    // MARK: - 4. Priority Resolution

    func testHigherPriorityOverridesLowerPriority() {
        let dailyMorning = ThemeScheduleItem(
            id: "daily_morning",
            title: "Daily Morning",
            priority: 10,
            timeRange: "05:00-11:59",
            theme: SeasonalThemeConfig(isEnabled: true, themeName: "summer", bannerTitle: "Daily Morning")
        )

        let tetSpecial = ThemeScheduleItem(
            id: "tet_special",
            title: "Tet Festival",
            priority: 100,
            startDate: "01-20",
            endDate: "02-10",
            theme: SeasonalThemeConfig(isEnabled: true, themeName: "tet", bannerTitle: "Tet Festival")
        )

        let baseConfig = SeasonalThemeConfig(
            isEnabled: true,
            themeName: "spring",
            bannerTitle: "Default Spring",
            schedules: [dailyMorning, tetSpecial]
        )

        // Date during Tet in the morning: priority 100 (Tet) should win over priority 10 (Morning)
        let tetMorning = makeDate(year: 2026, month: 1, day: 25, hour: 8, minute: 0)
        let resolved = baseConfig.resolveActiveTheme(at: tetMorning, calendar: calendar)

        XCTAssertEqual(resolved.themeName, "tet")
        XCTAssertEqual(resolved.bannerTitle, "Tet Festival")
    }

    // MARK: - 5. Fallback Resolution

    func testFallbackToBaseThemeWhenNoScheduleMatches() {
        let dailyNight = ThemeScheduleItem(
            id: "night",
            title: "Night",
            priority: 10,
            timeRange: "23:00-04:59",
            theme: SeasonalThemeConfig(isEnabled: true, themeName: "halloween")
        )

        let baseConfig = SeasonalThemeConfig(
            isEnabled: true,
            themeName: "spring",
            bannerTitle: "Default Base Theme",
            schedules: [dailyNight]
        )

        // Afternoon (not night)
        let afternoon = makeDate(year: 2026, month: 6, day: 15, hour: 14, minute: 0)
        let resolved = baseConfig.resolveActiveTheme(at: afternoon, calendar: calendar)

        XCTAssertEqual(resolved.themeName, "spring")
        XCTAssertEqual(resolved.bannerTitle, "Default Base Theme")
    }

    // MARK: - 6. Next Transition Date Calculation

    func testNextTransitionDateForTimeRanges() {
        let morning = ThemeScheduleItem(
            id: "morning",
            priority: 10,
            timeRange: "05:00-11:59",
            theme: SeasonalThemeConfig(isEnabled: true, themeName: "summer")
        )
        let afternoon = ThemeScheduleItem(
            id: "afternoon",
            priority: 10,
            timeRange: "12:00-17:59",
            theme: SeasonalThemeConfig(isEnabled: true, themeName: "autumn")
        )

        let config = SeasonalThemeConfig(isEnabled: true, themeName: "default", schedules: [morning, afternoon])

        // At 08:00, next transition should be end of morning (12:00:00)
        let dateAt8am = makeDate(year: 2026, month: 5, day: 10, hour: 8, minute: 0)
        let next = config.nextTransitionDate(from: dateAt8am, calendar: calendar)

        XCTAssertNotNil(next)
        if let next {
            let nextHour = calendar.component(.hour, from: next)
            let nextMin = calendar.component(.minute, from: next)
            XCTAssertEqual(nextHour, 12)
            XCTAssertEqual(nextMin, 0)
        }
    }

    // MARK: - 7. RemoteConfig JSON Dual-Decoding

    func testRemoteConfigPayloadWithSchedulesDecodesCorrectly() throws {
        let json = """
        {
            "seasonal_theme": {
                "is_enabled": true,
                "theme_name": "spring",
                "accent_color_light": "#16A34A",
                "accent_color_dark": "#4ADE80",
                "schedules": [
                    {
                        "id": "xmas",
                        "title": "Christmas",
                        "priority": 100,
                        "start_date": "12-20",
                        "end_date": "12-26",
                        "theme": {
                            "is_enabled": true,
                            "theme_name": "christmas",
                            "accent_color_light": "#DC2626",
                            "banner_title": "Merry Xmas"
                        }
                    }
                ]
            }
        }
        """

        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppRemoteConfig.self, from: data)

        XCTAssertTrue(config.seasonalTheme.isEnabled)
        XCTAssertEqual(config.seasonalTheme.themeName, "spring")
        XCTAssertEqual(config.seasonalTheme.schedules.count, 1)

        let schedule = config.seasonalTheme.schedules[0]
        XCTAssertEqual(schedule.id, "xmas")
        XCTAssertEqual(schedule.priority, 100)
        XCTAssertEqual(schedule.startDate, "12-20")
        XCTAssertEqual(schedule.endDate, "12-26")
        XCTAssertEqual(schedule.theme.themeName, "christmas")
        XCTAssertEqual(schedule.theme.bannerTitle, "Merry Xmas")
    }
}
