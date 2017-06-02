//
//  Flow.swift
//  Movies
//
//  Created by Göksel Köksal on 22/05/2017.
//  Copyright © 2017 GK. All rights reserved.
//

import Foundation

protocol NavigationIntent: Action { }

struct NavigationRequest {
    
    typealias Creation = (parent: AnyFlow, flow: AnyFlow)

    let from: AnyFlow
    let to: AnyFlow
    let creations: [Creation]
    let deletions: [AnyFlow]
    let info: [AnyHashable: Any]
    
    init(from: AnyFlow, to: AnyFlow, creations: [Creation], deletions: [AnyFlow], info: [AnyHashable: Any] = [:]) {
        self.from = from
        self.to = to
        self.creations = creations
        self.deletions = deletions
        self.info = info
    }
}

protocol NavigationResolver {
    func resolve(_ intent: NavigationIntent) -> NavigationRequest?
}

protocol NavigationPerformer {
    func perform(_ request: NavigationRequest)
}

protocol Dispatcher {
    func dispatch(_ action: Action)
    func dispatch<C: Command>(_ command: C)
}

final class Coordinator: Dispatcher {
    
    let navigationTree: Tree<AnyFlow>
    private(set) var middlewares: [Middleware]
    private let jobQueue = DispatchQueue(label: "flow.queue", qos: .userInitiated, attributes: [])
    
    init(rootFlow: AnyFlow, middlewares: [Middleware] = []) {
        self.navigationTree = Tree(rootFlow, equalityChecker: { $0 === $1 })
        self.middlewares = middlewares
        rootFlow.coordinator = self
    }
    
    func dispatch(_ action: Action) {
        jobQueue.async {
            self.willProcess(action)
            self.navigationTree.forEach { (flow) in
                if let navigationRequest = flow.process(action) {
                    for flowToDelete in navigationRequest.deletions {
                        self.navigationTree.remove(flowToDelete)
                    }
                    for (parent, flow) in navigationRequest.creations {
                        flow.coordinator = self
                        self.navigationTree.search(parent)?.add(flow)
                    }
                }
            }
            self.didProcess(action)
        }
    }
    
    func dispatch<C: Command>(_ command: C) {
        jobQueue.async {
            self.navigationTree.forEach { (flow) in
                if let specificFlow = flow as? Flow<C.StateType> {
                    command.execute(on: specificFlow, coordinator: self)
                }
            }
        }
    }
    
    private func willProcess(_ action: Action) {
        middlewares.forEach { $0.willProcess(action) }
    }
    
    private func didProcess(_ action: Action) {
        middlewares.forEach { $0.didProcess(action) }
    }
}

// MARK: Flow

protocol FlowID { }

protocol AnyFlow: class {
    weak var coordinator: Coordinator? { get set }
    var id: FlowID { get }
    var navigationResolver: NavigationResolver? { get }
    func process(_ action: Action) -> NavigationRequest?
}

class Flow<StateType: State>: AnyFlow {
    
    weak var coordinator: Coordinator?
    
    let id: FlowID
    private(set) var state: StateType
    let navigationResolver: NavigationResolver?
    
    private let jobQueue = DispatchQueue(label: "flow.queue", qos: .userInitiated, attributes: [])
    private let subscriptionsSyncQueue = DispatchQueue(label: "flow.subscription.sync")
    
    private var _subscriptions: [Subscription] = []
    private var subscriptions: [Subscription] {
        get {
            return subscriptionsSyncQueue.sync {
                return self._subscriptions
            }
        }
        set {
            subscriptionsSyncQueue.sync {
                self._subscriptions = newValue
            }
        }
    }
    
    init(id: FlowID, state: StateType, navigationResolver: NavigationResolver? = nil) {
        self.id = id
        self.state = state
        self.navigationResolver = navigationResolver
    }
    
    func process(_ action: Action) -> NavigationRequest? {
        if let intent = action as? NavigationIntent {
            let request = self.navigationResolver?.resolve(intent)
            self.notifySubscribers(with: request)
            return request
        } else {
            self.state.react(to: action)
            self.notifySubscribers(with: self.state)
            return nil
        }
    }
    
    func subscribe<S: Subscriber>(_ subscriber: S, on queue: DispatchQueue = .main) where S.StateType == StateType {
        jobQueue.sync {
            guard !self.subscriptions.contains(where: { $0.subscriber === subscriber }) else { return }
            let subscription = Subscription(subscriber: subscriber, queue: queue)
            self.subscriptions.append(subscription)
        }
    }
    
    func unsubscribe<S: Subscriber>(_ subscriber: S) where S.StateType == StateType {
        if let subscriptionIndex = subscriptions.index(where: { $0.subscriber === subscriber }) {
            subscriptions.remove(at: subscriptionIndex)
        }
    }
    
    private func notifySubscribers(with newState: StateType) {
        forEachSubscription { $0.notify(with: newState) }
    }
    
    private func notifySubscribers(with navigationRequest: NavigationRequest?) {
        guard let navigationRequest = navigationRequest else { return }
        forEachSubscription { $0.notify(with: navigationRequest) }
    }
    
    private func forEachSubscription(_ block: (Subscription) -> Void) {
        subscriptions = subscriptions.filter { $0.subscriber != nil }
        for subscription in subscriptions {
            block(subscription)
        }
    }
}

extension Flow: Dispatcher {
    
    func dispatch(_ action: Action) {
        coordinator?.dispatch(action)
    }
    
    func dispatch<C>(_ command: C) where C : Command {
        coordinator?.dispatch(command)
    }
}

// MARK: Actions

protocol Action { }

// MARK: Command

protocol Command {
    associatedtype StateType: State
    func execute(on flow: Flow<StateType>, coordinator: Coordinator)
}

// MARK: Subscriber

protocol AnySubscriber: class, NavigationPerformer {
    func _update(with state: State)
}

protocol Subscriber: AnySubscriber {
    associatedtype StateType: State
    func update(with state: StateType)
}

extension Subscriber {
    func _update(with state: State) {
        guard let state = state as? StateType else { return }
        update(with: state)
    }
}

struct Subscription {
    
    private(set) weak var subscriber: AnySubscriber?
    let queue: DispatchQueue
    
    fileprivate func notify(with newState: State) {
        queue.async {
            self.subscriber?._update(with: newState)
        }
    }
    
    fileprivate func notify(with navigationRequest: NavigationRequest) {
        queue.async {
            self.subscriber?.perform(navigationRequest)
        }
    }
}

// MARK: State

protocol State {
    mutating func react(to action: Action)
}

// MARK: Middleware

protocol Middleware {
    func willProcess(_ action: Action)
    func didProcess(_ action: Action)
}
