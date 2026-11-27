import AppKit
import TerminalCore

struct SupervisorTargetSelection: Equatable, Hashable {
    let paneID: String
    let generation: String?
    init(_ target: SupervisorTarget) { paneID = target.paneID; generation = target.generation }
}

struct SupervisorTargetActionOwner {
    let isCurrent: @MainActor () -> Bool
    let goToSession: (@MainActor (SupervisorContinuationIdentity) throws -> Void)?
}

struct SupervisorTargetActionServices: @unchecked Sendable {
    let validateTarget: @Sendable (SupervisorContinuationAuthority, SupervisorContinuationIdentity) throws -> Void
    let reviewInput: @Sendable (SupervisorContinuationAuthority, SupervisorContinuationIdentity) throws -> Void
    let captureOwner: @MainActor (SupervisorContinuationAuthority, SupervisorContinuationIdentity) -> SupervisorTargetActionOwner?
    var didReview: @MainActor () -> Void = {}
}

private final class SupervisorTargetActionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func revoke() { lock.lock(); active = false; lock.unlock() }
}

@MainActor final class SupervisorTargetActionsModel {
    let services: SupervisorTargetActionServices
    let scheduler: SupervisorPanelScheduling
    private(set) var targets: [SupervisorTarget] = []
    private(set) var selection: SupervisorTargetSelection?
    private(set) var authority: SupervisorContinuationAuthority?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    var onChange: (() -> Void)?
    private var panelBusy = false
    private var initializedSelection = false
    private var active: SupervisorTargetActionLease?
    private struct ReviewBarrier {
        let reference: SupervisorContinuationIdentity
        let revision: UInt64?
        var sawUnknown = false
    }
    private var reviewBarriers: [ReviewBarrier] = []

    init(services: SupervisorTargetActionServices, scheduler: SupervisorPanelScheduling) {
        self.services = services; self.scheduler = scheduler
    }

    private var selected: SupervisorTarget? {
        guard let selection else { return nil }
        let matches = targets.filter { SupervisorTargetSelection($0) == selection }
        return matches.count == 1 ? matches.first : nil
    }
    var disabledReason: String? {
        if isBusy || panelBusy { return "An action is in progress" }
        guard authority != nil else { return "Supervisor identity unavailable" }
        guard selection != nil else { return "Select a session" }
        guard let selected else { return "Session identity is ambiguous" }
        guard selected.alive else { return "Session is offline" }
        guard selected.reference != nil else { return "Session identity unavailable" }
        return nil
    }
    var readiness: SupervisorInputReadinessState? {
        guard let selected else { return nil }
        if let reference = selected.reference, reviewBarriers.contains(where: { $0.reference == reference }), selected.inputReadiness?.state == .ready {
            return .inputReviewRequired
        }
        return selected.inputReadiness?.state ?? .inputReviewRequired
    }
    func update(authority: SupervisorContinuationAuthority?, targets: [SupervisorTarget], panelBusy: Bool = false) {
        let oldAuthority = self.authority, oldReference = selected?.reference
        self.authority = authority; self.targets = targets; self.panelBusy = panelBusy
        if !initializedSelection, let first = targets.first {
            selection = SupervisorTargetSelection(first); initializedSelection = true
        } else if let selection, !targets.contains(where: { SupervisorTargetSelection($0) == selection }) {
            self.selection = nil
        }
        if oldAuthority != authority || oldReference != selected?.reference { active?.revoke() }
        reviewBarriers = reviewBarriers.compactMap { previous in
            guard let current = targets.first(where: { $0.reference == previous.reference }) else { return nil }
            var barrier = previous
            if current.inputReadiness?.state != .ready { barrier.sawUnknown = true }
            if barrier.sawUnknown, current.inputReadiness?.state == .ready,
               let revision = current.inputReadiness?.revision, barrier.revision.map({ revision > $0 }) ?? true { return nil }
            return barrier
        }
        onChange?()
    }
    func select(_ key: SupervisorTargetSelection?) {
        guard key != selection else { return }
        active?.revoke(); selection = key; errorMessage = nil; onChange?()
    }
    func navigationIsCurrent(authority: SupervisorContinuationAuthority, target: SupervisorContinuationIdentity) -> Bool {
        self.authority == authority && selected?.reference == target && selected?.alive == true
    }
    func goToSession() { run(review: false) }
    func reviewInput() { run(review: true) }
    func cancel() { active?.revoke() }

    private func run(review: Bool) {
        guard disabledReason == nil, let authority, let target = selected?.reference else { return }
        guard let owner = services.captureOwner(authority, target), owner.isCurrent() else {
            errorMessage = "Session window unavailable"; onChange?(); return
        }
        guard review || owner.goToSession != nil else { errorMessage = "Session navigation unavailable"; onChange?(); return }
        let lease = SupervisorTargetActionLease(), services = services, scheduler = scheduler
        active = lease; isBusy = true; errorMessage = nil; onChange?()
        scheduler.schedule { [weak self] in
            let result = Result {
                guard lease.isValid else { throw TerminalError.invalid("Session selection changed") }
                try services.validateTarget(authority, target)
            }
            scheduler.deliver { [weak self] in
                guard let self else { return }
                guard lease.isValid, owner.isCurrent() else { self.finish(lease); return }
                switch result {
                case .failure(let error): self.finish(lease, error: error)
                case .success:
                    if review {
                        self.reviewBarriers.removeAll { $0.reference == target }
                        self.reviewBarriers.append(ReviewBarrier(reference: target, revision: self.selected?.inputReadiness?.revision))
                        self.onChange?()
                        scheduler.schedule { [weak self] in
                            let reviewed = Result {
                                guard lease.isValid else { throw TerminalError.invalid("Session selection changed") }
                                try services.reviewInput(authority, target)
                            }
                            scheduler.deliver { [weak self] in
                                guard let self else { return }
                                guard lease.isValid, owner.isCurrent() else { self.finish(lease); return }
                                switch reviewed {
                                case .failure(let error): self.finish(lease, error: error); services.didReview()
                                case .success:
                                    self.finish(lease)
                                    services.didReview()
                                }
                            }
                        }
                    } else {
                        do { try owner.goToSession?(target); self.finish(lease) }
                        catch { self.finish(lease, error: error) }
                    }
                }
            }
        }
    }
    private func finish(_ lease: SupervisorTargetActionLease, error: Error? = nil) {
        guard active === lease else { return }
        active = nil; isBusy = false; errorMessage = error?.localizedDescription; onChange?()
    }
}

@MainActor final class SupervisorTargetActionsView: NSView {
    let model: SupervisorTargetActionsModel
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let go = NSButton(title: "Go to Session", target: nil, action: nil)
    private let review = NSButton(title: "Review Input", target: nil, action: nil)
    private let state = NSTextField(labelWithString: "")
    init(model: SupervisorTargetActionsModel) {
        self.model = model; super.init(frame: .zero)
        for (view, id) in [(picker, "supervisor-target-picker"), (go, "supervisor-target-go"),
            (review, "supervisor-target-review"), (state, "supervisor-target-state")] {
            view.identifier = NSUserInterfaceItemIdentifier(id); view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        picker.target = self; picker.action = #selector(selectTarget)
        picker.setAccessibilityLabel("Supervisor target session")
        go.target = self; go.action = #selector(goClicked); go.bezelStyle = .rounded
        review.target = self; review.action = #selector(reviewClicked); review.bezelStyle = .rounded
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor
        state.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            picker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            picker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), picker.heightAnchor.constraint(equalToConstant: 26),
            go.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 4), go.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            go.widthAnchor.constraint(equalToConstant: 130), go.heightAnchor.constraint(equalToConstant: 26),
            review.leadingAnchor.constraint(equalTo: go.trailingAnchor, constant: 6), review.centerYAnchor.constraint(equalTo: go.centerYAnchor),
            review.widthAnchor.constraint(equalToConstant: 130), review.heightAnchor.constraint(equalToConstant: 26),
            state.topAnchor.constraint(equalTo: go.bottomAnchor, constant: 4), state.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), state.heightAnchor.constraint(equalToConstant: 18)
        ])
        model.onChange = { [weak self] in self?.render() }
        render()
    }
    required init?(coder: NSCoder) { nil }
    private func render() {
        picker.removeAllItems()
        if model.targets.isEmpty { picker.addItem(withTitle: "No sessions") }
        for target in model.targets { picker.addItem(withTitle: target.title.isEmpty ? "Session" : target.title) }
        if let key = model.selection, let index = model.targets.firstIndex(where: { SupervisorTargetSelection($0) == key }) {
            picker.selectItem(at: index)
        } else { picker.select(nil) }
        picker.isEnabled = !model.isBusy && !model.targets.isEmpty
        go.isEnabled = model.disabledReason == nil; review.isEnabled = model.disabledReason == nil
        go.toolTip = model.disabledReason; review.toolTip = model.disabledReason
        let label: String
        switch model.readiness {
        case .ready: label = "Ready"
        case .inputInFlight: label = "Input in flight"
        case .inputReviewRequired: label = "Awaiting a new submission"
        case .changed: label = "Session changed"
        case nil: label = ""
        }
        state.stringValue = model.errorMessage ?? model.disabledReason ?? label
        state.toolTip = state.stringValue
    }
    @objc private func selectTarget() {
        let index = picker.indexOfSelectedItem
        model.select(model.targets.indices.contains(index) ? SupervisorTargetSelection(model.targets[index]) : nil)
    }
    @objc private func goClicked() { model.goToSession() }
    @objc private func reviewClicked() { model.reviewInput() }
}
