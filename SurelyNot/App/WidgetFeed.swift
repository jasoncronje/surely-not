import BackgroundTasks
import WidgetKit

/// Keeps the home screen widget's figures current.
enum WidgetFeed {
    /// The name of the background refresh, as listed in Info.plist.
    nonisolated static let refreshTask = "io.cronje.surelynot.refresh"
    /// How long a budget figure read for the widget is good for.
    nonisolated static let budgetMaxAge: TimeInterval = 15 * 60

    /// Turns this month's bills and budget into what the widget shows.
    nonisolated static func snapshot(
        statuses: [BillStatus],
        budget: WidgetSnapshot.Budget?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> WidgetSnapshot {
        // The widget shows one sum, so it shows only bills in the main
        // currency rather than adding dollars to euros.
        let currency = BillSchedule.mainCurrency(of: statuses.filter { !$0.bill.isIncome })
        let outgoing = statuses.filter { !$0.bill.isIncome && $0.bill.currency == currency }
        return WidgetSnapshot(
            updatedAt: now,
            month: WidgetSnapshot.monthKey(now, calendar: calendar),
            currency: currency,
            bills: outgoing.map { status in
                WidgetSnapshot.Bill(
                    id: status.bill.id,
                    name: status.bill.title,
                    cents: status.cents,
                    dueDate: status.dueDate,
                    isPaid: status.isPaid,
                    autopay: status.bill.autopay == true
                )
            },
            budget: budget
        )
    }

    /// Saves the bills just loaded, with this month's budget, and redraws the
    /// widget. The budget is a nicety: if it cannot be loaded the widget
    /// shows bills alone.
    static func publish(statuses: [BillStatus], client: APIClient) async {
        let saved = WidgetStore.load()
        // Bills load each time Overview shows. When the bills are unchanged
        // and the budget was read in the last quarter hour, leave the
        // server alone rather than asking for the budget again.
        if let saved, Date.now.timeIntervalSince(saved.updatedAt) < budgetMaxAge,
           snapshot(statuses: statuses, budget: saved.budget, now: saved.updatedAt) == saved {
            return
        }
        let budget = try? await currentBudget(client: client)
        guard !Task.isCancelled else { return }
        let fresh = snapshot(statuses: statuses, budget: budget)
        // Only the time differs on most loads; skip the redraw then.
        var comparable = fresh
        comparable.updatedAt = saved?.updatedAt ?? fresh.updatedAt
        guard comparable != saved else { return }
        if WidgetStore.save(fresh) {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetStore.widgetKind)
        }
    }

    /// What has been spent against this month's budget. With no budget set,
    /// it is this month's spending with nothing to compare it to.
    private static func currentBudget(client: APIClient) async throws -> WidgetSnapshot.Budget? {
        guard let budget = try await client.budgets().first(where: { $0.current == true }),
              let cents = budget.budgetedSpendingCents, cents > 0 else {
            let spending = try await client.spendingVsNormal()
            return WidgetSnapshot.Budget(spent: max(MoneyFormat.double(spending.total), 0), budgeted: 0)
        }
        let spending = try await client.spendingVsNormal(startDate: budget.startDate, endDate: budget.endDate)
        let budgeted = MoneyFormat.decimal(cents: cents, currency: budget.currency)
        return WidgetSnapshot.Budget(
            spent: max(MoneyFormat.double(spending.total), 0),
            budgeted: NSDecimalNumber(decimal: budgeted).doubleValue
        )
    }

    /// Removes the saved figures, so a signed-out phone shows none.
    static func clear() {
        WidgetStore.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetStore.widgetKind)
    }

    /// Asks iOS to wake the app now and then to refresh the widget. iOS
    /// decides when, and may not do it at all for an app that is rarely used.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The work of one background wake: load the bills, which publishes them.
    static func refresh(client: APIClient) async {
        scheduleRefresh()
        await BillsModel(client: client).load()
    }
}
