import SwiftUI
import WidgetKit

struct BillsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// Reads what the app last saved. One entry per day for the week ahead, so
/// "Due in 3 days" counts down without the app being opened.
struct BillsProvider: TimelineProvider {
    func placeholder(in context: Context) -> BillsEntry {
        BillsEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (BillsEntry) -> Void) {
        completion(BillsEntry(date: .now, snapshot: context.isPreview ? .sample : WidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<BillsEntry>) -> Void) {
        let snapshot = WidgetStore.load()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var entries = [BillsEntry(date: .now, snapshot: snapshot)]
        for offset in 1...7 {
            if let midnight = calendar.date(byAdding: .day, value: offset, to: today) {
                entries.append(BillsEntry(date: midnight, snapshot: snapshot))
            }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

extension WidgetSnapshot {
    /// Made-up figures for the widget gallery.
    static let sample = WidgetSnapshot(
        updatedAt: .now,
        month: WidgetSnapshot.monthKey(.now),
        currency: "USD",
        bills: [
            Bill(id: "1", name: "Rent", cents: 180_000, dueDate: sampleDay(2), isPaid: false, autopay: false),
            Bill(id: "2", name: "Internet", cents: 6_000, dueDate: sampleDay(5), isPaid: false, autopay: true),
            Bill(id: "3", name: "Music", cents: 1_299, dueDate: sampleDay(9), isPaid: false, autopay: true),
        ],
        budget: Budget(spent: 2_150, budgeted: 3_400)
    )

    private static func sampleDay(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: .now) ?? .now
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

struct BillsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.widgetKind, provider: BillsProvider()) { entry in
            BillsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Bills")
        .description("What is still to pay this month, and what is due next.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct BillsWidgetView: View {
    let entry: BillsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot, snapshot.isCurrent(at: entry.date) {
            switch family {
            case .systemMedium: MediumView(snapshot: snapshot, date: entry.date)
            case .accessoryRectangular: LockScreenView(snapshot: snapshot, date: entry.date)
            default: SmallView(snapshot: snapshot, date: entry.date)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bills")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Open Surely Not to load this month's bills.")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The amount still to pay, with its label above.
private struct ToPay: View {
    let snapshot: WidgetSnapshot
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("To pay in \(date.formatted(.dateTime.month(.abbreviated)))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if snapshot.unpaid.isEmpty {
                Label("All paid", systemImage: "checkmark.circle.fill")
                    .font(.headline)
            } else {
                Text(WidgetSnapshot.money(cents: snapshot.toPayCents, currency: snapshot.currency, whole: true))
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
    }
}

struct SmallView: View {
    let snapshot: WidgetSnapshot
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToPay(snapshot: snapshot, date: date)
            Spacer(minLength: 6)
            if let next = snapshot.unpaid.first {
                Text(next.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .privacySensitive()
                Text(WidgetSnapshot.dueLine(for: next, at: date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !snapshot.bills.isEmpty {
                Text("\(snapshot.bills.count) bills this month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MediumView: View {
    let snapshot: WidgetSnapshot
    let date: Date

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                ToPay(snapshot: snapshot, date: date)
                Spacer(minLength: 6)
                if let budget = snapshot.budget, budget.budgeted > 0 {
                    Text("Budget")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    BudgetBar(fraction: budget.fraction)
                        .padding(.vertical, 3)
                    Text("\(WidgetSnapshot.money(Decimal(budget.spent), currency: snapshot.currency, whole: true)) of \(WidgetSnapshot.money(Decimal(budget.budgeted), currency: snapshot.currency, whole: true))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .privacySensitive()
                } else if let budget = snapshot.budget {
                    Text("Spent in \(date.formatted(.dateTime.month(.abbreviated)))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(WidgetSnapshot.money(Decimal(budget.spent), currency: snapshot.currency, whole: true))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .privacySensitive()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 8) {
                if snapshot.unpaid.isEmpty {
                    Text("Nothing left to pay this month.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.unpaid.prefix(3)) { bill in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(bill.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(WidgetSnapshot.dueLine(for: bill, at: date))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(WidgetSnapshot.money(cents: bill.cents, currency: snapshot.currency, whole: true))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .privacySensitive()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// How much of the budget is used. Red once it is over.
private struct BudgetBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fraction > 1 ? Color.red : Color.blue)
                    .frame(width: max(geometry.size.width * min(max(fraction, 0), 1), 4))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

struct LockScreenView: View {
    let snapshot: WidgetSnapshot
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let next = snapshot.unpaid.first {
                Text(next.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(WidgetSnapshot.dueLine(for: next, at: date))
                Text(WidgetSnapshot.money(cents: next.cents, currency: snapshot.currency))
                    .foregroundStyle(.secondary)
            } else {
                Text("Bills")
                    .font(.headline)
                Text("All paid this month")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .privacySensitive()
    }
}
