import SwiftUI

/// The Calendar section (SPEC V55): budget rings, a metric picker, and month grids for every
/// retained month, newest first, beside the selected day's panel. Chips filter the grids
/// (V53). Markers follow V56: `~$` and a lighter fill for estimated, dashed borders for
/// partial days, "incomplete" months, "backfilled" cards, local runtimes as presence only.
struct DashboardCalendarView: View {
    @Bindable var model: DashboardModel
    let budgets: [DashboardBudget]
    let warningFraction: Double

    var body: some View {
        let calendar = model.calendar
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !budgets.isEmpty { rings }
                    HStack {
                        Picker("Colour by", selection: $model.calendarMetric) {
                            ForEach(DashboardCalendar.Metric.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                        Spacer()
                    }
                    DashboardChips(model: model, ids: calendar.chipProviders)
                    legend(calendar.metric)
                    ForEach(calendar.months) { month(calendar, $0) }
                }
                .padding(20)
            }
            .frame(minWidth: 420)
            Divider()
            DashboardDayPanel(panel: calendar.panel(model.selectedDay ?? model.today), focus: model.focus)
                .frame(width: 340)
        }
    }

    // MARK: - Budget rings

    private var rings: some View {
        HStack(alignment: .top, spacing: 22) {
            ForEach(budgets) { budget in
                DashboardBudgetRing(
                    label: budget.scope.providerID?.displayHint ?? "Total", budget: budget,
                    warningFraction: warningFraction)
            }
        }
    }

    // MARK: - Months

    private func legend(_ metric: DashboardCalendar.Metric) -> some View {
        let text: String
        switch metric {
        case .spend: text = "cell = metered spend · lighter = estimated (~$)"
        case .value: text = "cell = subscription value (~$), API-equivalent, not spend"
        case .quotaPeak: text = "cell = highest quota peak: under 80% · 80% · 95% · 100%"
        }
        return DashboardNote(text + " · dashed = partial or no data · dot = usage event")
    }

    private func month(_ calendar: DashboardCalendar, _ month: DashboardCalendar.Month) -> some View {
        let columns = Array(repeating: GridItem(.flexible(minimum: 40, maximum: 72), spacing: 4), count: 7)
        let title = DashboardRange.date(forKey: "\(month.key)-01").formatted(.dateTime.month(.wide).year())
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if month.incomplete { DashboardBadge(text: "incomplete") }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(Self.weekdaySymbols.indices, id: \.self) { i in
                    Text(Self.weekdaySymbols[i]).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(0..<month.leadingBlanks, id: \.self) { _ in Color.clear.frame(height: 44) }
                ForEach(month.days) { cell(calendar, $0) }
            }
            .frame(maxWidth: 540)
        }
    }

    private func cell(_ calendar: DashboardCalendar, _ day: DashboardCalendar.Day) -> some View {
        let selected = day.key == (model.selectedDay ?? model.today)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Text("\(day.dayOfMonth)").font(.caption2.bold())
                Spacer(minLength: 0)
                if day.hasEvent { Circle().fill(.pink).frame(width: 6, height: 6) }
            }
            Spacer(minLength: 0)
            if day.retained, let text = label(calendar.metric, day) {
                Text(text).font(.system(size: 9).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            }
            if day.isToday {
                Text("in progress").font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(3)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 4).fill(fill(calendar, day)))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary, lineWidth: 2)
            } else if day.partial {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3]))
            }
        }
        .opacity(day.retained ? 1 : 0.3)
        .contentShape(Rectangle())
        .onTapGesture { if day.retained { model.selectedDay = day.key } }
    }

    private func label(_ metric: DashboardCalendar.Metric, _ day: DashboardCalendar.Day) -> String? {
        switch metric {
        case .spend: return day.amount.map { dashboardUSD($0, approximate: day.estimated) }
        case .value: return day.amount.map { dashboardUSD($0, approximate: true) }
        case .quotaPeak: return day.peak.map { "\(Int(($0 * 100).rounded()))%" }
        }
    }

    private func fill(_ calendar: DashboardCalendar, _ day: DashboardCalendar.Day) -> Color {
        guard day.retained else { return .clear }
        switch calendar.metric {
        case .spend, .value:
            guard let amount = day.amount, calendar.top > 0 else { return Color.secondary.opacity(0.08) }
            let share = NSDecimalNumber(decimal: amount / calendar.top).doubleValue
            // Value is dimmed beside spend (V26); estimated is lighter (V56).
            let base: Color = calendar.metric == .spend ? .orange : .secondary
            return base.opacity((0.12 + 0.68 * share) * (day.estimated || calendar.metric == .value ? 0.6 : 1))
        case .quotaPeak:
            guard let peak = day.peak else { return Color.secondary.opacity(0.08) }
            return DashboardPalette.band(DashboardQuotaCell.band(peak: peak)).opacity(0.7)
        }
    }

    /// Weekday headers in the locale's order, starting at its first weekday.
    private static var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }
}

/// One month budget as a ring: month spend against the cap, coloured by band (V55).
struct DashboardBudgetRing: View {
    let label: String
    let budget: DashboardBudget
    let warningFraction: Double

    var body: some View {
        let fraction = budget.fraction
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: min(fraction, 1))
                    .stroke(
                        fraction >= 1 ? Color.red : fraction >= warningFraction ? .orange : .accentColor,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.caption.bold())
            }
            .frame(width: 60, height: 60)
            Text(label).font(.caption.bold())
            Text("\(dashboardUSD(budget.spend.amount ?? 0, approximate: budget.spend.estimated)) of \(dashboardUSD(budget.cap.amount))")
                .font(.caption2.monospacedDigit())
            if budget.spend.incomplete { DashboardBadge(text: "incomplete") }
        }
    }
}

/// The selected day: a card per provider with spend and value side by side, quota peak and
/// end-of-day bars, accounts, and events (V55). Today is "in progress".
struct DashboardDayPanel: View {
    let panel: DashboardCalendar.Panel
    /// The deep link that opened this day, if any (V58).
    var focus: DashboardRoute?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(DashboardRange.date(forKey: panel.key).formatted(.dateTime.weekday(.wide).month().day().year()))
                        .font(.title3.bold())
                    if panel.isToday { DashboardBadge(text: "in progress") }
                }
                if panel.cards.isEmpty { DashboardNote("No data for this day.") }
                ForEach(panel.cards) { card($0) }
                if !panel.budgetEvents.isEmpty {
                    DashboardSection("Total budget") { events(panel.budgetEvents) }
                }
            }
            .padding(16)
        }
    }

    private func card(_ card: DashboardCalendar.Card) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(DashboardPalette.color(card.provider)).frame(width: 8, height: 8)
                Text(card.provider.displayHint).bold()
                if card.record?.origin == .backfilled { DashboardBadge(text: "backfilled") }
                Spacer()
            }
            if let record = card.record {
                content(card, record)
            } else {
                DashboardNote("No data")
            }
            if !card.events.isEmpty { events(card.events) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if focus?.outlines(card.provider, on: panel.key) == true {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .opacity(card.record?.origin == .backfilled ? 0.75 : 1)
    }

    @ViewBuilder
    private func content(_ card: DashboardCalendar.Card, _ record: DayRecord) -> some View {
        if card.kind == .local {
            // Presence only, never $0 (V56).
            DashboardNote("Running · no cost data")
        } else {
            let split = record.costSplit
            HStack(spacing: 16) {
                if split.hasMetered {
                    amount("Spend", split.spend.map { dashboardUSD($0.amount, approximate: split.estimated) })
                }
                if split.hasSubscription {
                    amount("Value", split.value.map { dashboardUSD($0.amount, approximate: true) }, dimmed: true)
                }
                amount("Tokens", record.tokens.map { $0.formatted(.number.notation(.compactName)) })
            }
            ForEach(record.quota.keys.sorted(), id: \.self) { window in
                if let quota = record.quota[window] { quotaBar(window, quota) }
            }
            ForEach(record.accounts, id: \.key) { account in
                let plan = account.plan.map { " · \($0)" } ?? ""
                let cost = account.costUSD.map {
                    " · " + dashboardUSD($0.amount, approximate: account.billingModel == .subscription || record.costEstimated)
                } ?? ""
                Text("\(account.label) · \(account.billingModel.rawValue)\(plan)\(cost)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func amount(_ title: String, _ value: String?, dimmed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "—").font(.callout.monospacedDigit()).foregroundStyle(dimmed ? .secondary : .primary)
        }
    }

    /// The peak bar with an end-of-day tick (V55).
    private func quotaBar(_ window: String, _ quota: QuotaDay) -> some View {
        HStack(spacing: 6) {
            Text(window).font(.caption).frame(width: 34, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(DashboardPalette.band(DashboardQuotaCell.band(peak: quota.peak)))
                        .frame(width: width * min(quota.peak, 1))
                    Rectangle().fill(.primary).frame(width: 2, height: 10)
                        .offset(x: width * min(quota.endOfDay, 1) - 1)
                }
            }
            .frame(height: 6)
            Text("peak \(Int((quota.peak * 100).rounded()))% · end \(Int((quota.endOfDay * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .frame(width: 110, alignment: .trailing)
        }
    }

    private func events(_ events: [UsageEvent]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                HStack(spacing: 6) {
                    Image(systemName: DashboardPalette.symbol(event.kind))
                    Text(event.time.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                    Text([DashboardPalette.title(event.kind), event.window].compactMap { $0 }.joined(separator: " "))
                    if !event.notified { DashboardBadge(text: "not notified") }
                    if event.carriedOver { DashboardBadge(text: "carried over") }
                }
                .font(.caption)
                .padding(.horizontal, 4)
                .background {
                    if focus?.highlights(event, on: panel.key) == true {
                        RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.25))
                    }
                }
            }
        }
    }
}
